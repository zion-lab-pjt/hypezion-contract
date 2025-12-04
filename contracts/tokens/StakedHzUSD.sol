// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../libraries/StabilityPoolMath.sol";

/**
 * @title StakedHzUSD (shzUSD) - UUPS Upgradeable Version
 * @notice ERC4626 tokenized vault for Stability Pool in HypeZion Protocol
 * @dev NAV-based vault that reflects yield through share price appreciation
 */
contract StakedHzUSD is
    ERC4626Upgradeable,
    IStabilityPool,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant PRECISION = 1e18;

    // State variables
    address public protocol;
    address public xhype;
    address public yieldManager; // Authorized to compound yield
    bool private _isInterventionActive;
    uint256 public totalXHYPEFromIntervention;
    uint256 private _totalAssets; // DEPRECATED - DO NOT REMOVE (storage layout compatibility)

    // Recovery mode tracking
    uint256 public hzusdInPool;          // HzUSD amount in pool
    uint256 public hzhypeInPool;         // hzHYPE amount in pool

    // Events (additional to IStabilityPool)
    event ProtocolSet(address indexed newProtocol);
    event XHYPESet(address indexed newXHYPE);
    event YieldManagerSet(address indexed newYieldManager);
    event Deposited(address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    // Custom errors (additional to IStabilityPool)
    error ZeroAddress();
    error InvalidInterventionAmount();

    // Storage gap for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (replaces constructor)
     * @param _asset Address of the underlying asset (HzUSD)
     */
    function initialize(address _asset) external initializer {
        if (_asset == address(0)) revert ZeroAddress();

        __ERC20_init("Staked HypeZion USD", "shzUSD");
        __ERC4626_init(IERC20(_asset));
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Bootstrap roles after upgrade from Ownable version
     * @dev One-time function to grant roles after upgrading to AccessControl
     *      Can only be called once by anyone, grants roles to caller
     *      Required because upgraded contracts don't have initialize() called again
     */
    function bootstrapRoles() external {
        // Check if roles are already set (prevents calling this multiple times)
        require(!hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Roles already bootstrapped");

        // Grant both roles to the caller (should be deployer/admin)
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Set the protocol address that can trigger interventions
     * @param _protocol Address of the protocol/risk manager contract
     */
    function setProtocol(address _protocol) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_protocol == address(0)) revert ZeroAddress();
        protocol = _protocol;
        emit ProtocolSet(_protocol);
    }

    /**
     * @notice Set the hzHYPE token address for interventions
     * @param _xhype Address of the hzHYPE token contract
     */
    function setXHYPE(address _xhype) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_xhype == address(0)) revert ZeroAddress();
        xhype = _xhype;
        emit XHYPESet(_xhype);
    }

    /**
     * @notice Set the yield manager address that can compound yield
     * @param _yieldManager Address of the KinetiqYieldManager contract
     */
    function setYieldManager(address _yieldManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_yieldManager == address(0)) revert ZeroAddress();
        yieldManager = _yieldManager;
        emit YieldManagerSet(_yieldManager);
    }

    /**
     * @notice Protocol intervention to convert hzUSD to hzHYPE when CR < 130%
     * @param amountToConvert Amount of hzUSD to convert to hzHYPE
     * @param zhypeReceived Amount of hzHYPE received from conversion
     */
    function protocolIntervention(uint256 amountToConvert, uint256 zhypeReceived) external payable override {
        if (msg.sender != protocol) revert InvalidCaller(msg.sender);
        if (amountToConvert > totalAssets()) revert InsufficientPoolBalance(amountToConvert, totalAssets());

        // Validate received amount
        if (zhypeReceived == 0) revert InvalidInterventionAmount();

        // Mark intervention as active
        if (!_isInterventionActive) {
            _isInterventionActive = true;
            emit InterventionStateChanged(true);
        }

        // Update asset tracking
        hzusdInPool -= amountToConvert;
        hzhypeInPool += zhypeReceived;
        totalXHYPEFromIntervention += zhypeReceived;

        // hzhypeInPool > 0 now indicates recovery mode is active

        emit ProtocolIntervention(amountToConvert, zhypeReceived);
    }

    /**
     * @notice Exit recovery mode by converting hzHYPE back to hzUSD
     * @dev Called by protocol when CR becomes healthy (≥150%) to restore single-asset state
     * @param zhypeBurned Amount of hzHYPE burned from pool
     * @param zusdMinted Amount of hzUSD minted to pool
     */
    function exitRecoveryMode(uint256 zhypeBurned, uint256 zusdMinted) external override {
        if (msg.sender != protocol) revert InvalidCaller(msg.sender);

        // Validate amounts
        if (zhypeBurned > hzhypeInPool) {
            revert InsufficientPoolBalance(zhypeBurned, hzhypeInPool);
        }
        if (zhypeBurned == 0 || zusdMinted == 0) {
            revert InvalidInterventionAmount();
        }

        // Update asset tracking
        hzhypeInPool -= zhypeBurned;
        hzusdInPool += zusdMinted;

        // Clear intervention state if no hzHYPE remains
        if (hzhypeInPool == 0) {
            _isInterventionActive = false;
            emit InterventionStateChanged(false);
        }
    }

    /**
     * @notice Compound yield into the pool (increases NAV)
     * @param yieldAmount Amount of yield to compound
     */
    function compoundYield(uint256 yieldAmount) external override {
        if (msg.sender != protocol && msg.sender != yieldManager) revert InvalidCaller(msg.sender);

        // Yield is added to hzusdInPool (yield comes from underlying hzUSD)
        hzusdInPool += yieldAmount;

        uint256 newNAV = totalAssets();
        emit YieldCompounded(yieldAmount, newNAV);
    }

    /**
     * @notice Get the current NAV of the pool
     * @return Current net asset value
     */
    function getNAV() external view override returns (uint256) {
        return totalAssets();
    }

    /**
     * @notice Get the current share price (NAV per share)
     * @return Price per share in HzUSD terms
     */
    function getSharePrice() external view override returns (uint256) {
        if (totalSupply() == 0) {
            return 1e18; // Initial price is 1:1
        }

        // Get current NAV values from Exchange contract (real-time)
        uint256 zusdNavInHYPE = IHypeZionExchange(protocol).getZusdNavInHYPE();
        uint256 zhypeNavInHYPE = IHypeZionExchange(protocol).getZhypeNavInHYPE();

        // Use stability pool cap formula for recovery mode assets (returns value in HYPE)
        uint256 stabilityPoolCap = StabilityPoolMath.stabilityPoolCap(
            zusdNavInHYPE,
            hzusdInPool,
            zhypeNavInHYPE,
            hzhypeInPool
        );

        // Share price in HYPE terms
        uint256 sharePriceInHYPE = (stabilityPoolCap * PRECISION) / totalSupply();

        // Convert from HYPE to HzUSD: share price in HYPE / hzUSD NAV
        return (sharePriceInHYPE * PRECISION) / zusdNavInHYPE;
    }

    /**
     * @notice Check if pool is under intervention
     * @return True if intervention is active
     */
    function isInterventionActive() external view override returns (bool) {
        return _isInterventionActive;
    }

    /**
     * @notice Get pool balance in underlying asset
     * @return Balance amount
     */
    function poolBalance() external view override returns (uint256) {
        return totalAssets();
    }

    /// @notice Check if pool is in recovery mode (has converted assets)
    function isInRecoveryMode() external view returns (bool) {
        return _isInterventionActive && hzhypeInPool > 0;
    }

    /**
     * @notice Get total hzHYPE received from interventions
     * @return Total hzHYPE amount
     */
    function totalXHYPE() external view override returns (uint256) {
        return totalXHYPEFromIntervention;
    }

    /**
     * @notice Preview withdrawal with recovery mode asset breakdown
     */
    function previewMixedRedeem(uint256 shares)
        external
        view
        returns (
            uint256 stablecoinAmount,
            uint256 levercoinAmount,
            uint256 totalValue
        )
    {
        if (shares > totalSupply()) {
            revert InsufficientShares(shares, totalSupply());
        }

        // Calculate proportional amounts
        totalValue = StabilityPoolMath.amountTokenToWithdraw(
            shares,
            totalSupply(),
            totalAssets()
        );

        if (_isInterventionActive && hzhypeInPool > 0) {
            // Calculate proportional distribution
            stablecoinAmount = StabilityPoolMath.amountTokenToWithdraw(
                shares,
                totalSupply(),
                hzusdInPool
            );

            levercoinAmount = StabilityPoolMath.amountTokenToWithdraw(
                shares,
                totalSupply(),
                hzhypeInPool
            );
        } else {
            // Single asset scenario
            stablecoinAmount = totalValue;
            levercoinAmount = 0;
        }
    }

    /**
     * @notice Withdraw with recovery mode asset breakdown (proportional distribution)
     */
    function mixedWithdraw(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (
        uint256 stablecoinAmount,
        uint256 levercoinAmount,
        uint256 totalValue
    ) {
        if (msg.sender != receiver) {
            revert InvalidReceiver();
        }

        // Get current breakdown
        (stablecoinAmount, levercoinAmount, totalValue) = this.previewMixedRedeem(shares);

        // Burn LP tokens
        _burn(msg.sender, shares);

        // Calculate fees (if any)
        uint256 stablecoinFees = 0; // Could implement withdrawal fees later
        uint256 netStablecoin = stablecoinAmount - stablecoinFees;

        // Transfer assets
        if (netStablecoin > 0) {
            IERC20(asset()).transfer(receiver, netStablecoin);
        }

        if (levercoinAmount > 0) {
            IERC20(xhype).transfer(receiver, levercoinAmount);
        }

        // Update tracking
        hzusdInPool -= stablecoinAmount;
        hzhypeInPool -= levercoinAmount;

        emit Withdrawn(msg.sender, receiver, totalValue, shares);
    }

    /**
     * @notice Revert intervention state (for testing or emergency)
     * @dev Only callable by protocol
     */
    function revertIntervention() external override {
        if (msg.sender != protocol) revert InvalidCaller(msg.sender);

        if (_isInterventionActive) {
            _isInterventionActive = false;
            totalXHYPEFromIntervention = 0;
            emit InterventionStateChanged(false);
        }
    }

    /**
     * @dev Override totalAssets to calculate value dynamically in HzUSD terms
     * @return Total assets in HzUSD equivalent (always in HzUSD, never in HYPE)
     */
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        // If not in recovery mode, return simple calculation
        if (!_isInterventionActive || hzhypeInPool == 0) {
            return hzusdInPool;
        }

        // Get current NAV values from Exchange contract (real-time)
        uint256 zusdNavInHYPE = IHypeZionExchange(protocol).getZusdNavInHYPE();
        uint256 zhypeNavInHYPE = IHypeZionExchange(protocol).getZhypeNavInHYPE();

        // Calculate total pool value in HYPE terms
        uint256 totalValueInHYPE = StabilityPoolMath.stabilityPoolCap(
            zusdNavInHYPE,
            hzusdInPool,
            zhypeNavInHYPE,
            hzhypeInPool
        );

        // Convert HYPE value back to HzUSD equivalent
        return (totalValueInHYPE * PRECISION) / zusdNavInHYPE;
    }

    /**
     * @dev Override deposit to track assets
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        hzusdInPool += assets;
        emit Deposited(receiver, assets, shares);
        return shares;
    }

    /**
     * @dev Override withdraw to track assets
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256 shares) {
        if (assets > totalAssets()) revert InsufficientPoolBalance(assets, totalAssets());
        shares = super.withdraw(assets, receiver, owner);
        hzusdInPool -= assets;
        emit Withdrawn(owner, receiver, assets, shares);
        return shares;
    }

    /**
     * @dev Override redeem to track assets
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256 assets) {
        // Fail intentionally if in recovery mode (following Solana pattern)
        if (_isInterventionActive && hzhypeInPool > 0) {
            revert MixedAssetQuoteFailure();
        }

        assets = super.redeem(shares, receiver, owner);
        if (assets > totalAssets()) revert InsufficientPoolBalance(assets, totalAssets());
        hzusdInPool -= assets;
        emit Withdrawn(owner, receiver, assets, shares);
        return assets;
    }

    /**
     * @dev Override mint to track assets
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        hzusdInPool += assets;
        emit Deposited(receiver, assets, shares);
        return assets;
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to owner
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}