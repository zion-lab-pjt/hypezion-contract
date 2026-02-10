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

    // Unstake fee configuration (basis points, 10000 = 100%)
    // All tiers set to same value (0.1%) - can be adjusted per-tier in future if needed
    uint256 public unstakeFeeHealthy;    // Default: 10 (0.1%) when CR >= 150%
    uint256 public unstakeFeeCautious;   // Default: 10 (0.1%) when 130% <= CR < 150%
    uint256 public unstakeFeeCritical;   // Default: 10 (0.1%) when CR < 130%

    address public interventionManager;

    // Accumulated unstake fees pending admin collection
    uint256 public accumulatedUnstakeFees;        // hzUSD fees pending collection
    uint256 public accumulatedUnstakeFeesXHYPE;   // hzHYPE fees pending collection (recovery mode)

    // Events (additional to IStabilityPool)
    event ProtocolSet(address indexed newProtocol);
    event XHYPESet(address indexed newXHYPE);
    event YieldManagerSet(address indexed newYieldManager);
    event InterventionManagerSet(address indexed newInterventionManager);
    event Deposited(address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event MixedWithdrawn(address indexed owner, address indexed receiver, uint256 hzusdAmount, uint256 bullhypeAmount, uint256 totalValue, uint256 shares);
    event UnstakeFeeCharged(address indexed owner, uint256 fee, uint256 feeBps);
    event UnstakeFeesUpdated(uint256 feeHealthy, uint256 feeCautious, uint256 feeCritical);
    event UnstakeFeesCollected(address indexed recipient, uint256 hzusdAmount, uint256 xhypeAmount);

    // Custom errors (additional to IStabilityPool)
    error ZeroAddress();
    error InvalidInterventionAmount();
    error FeeTooHigh();

    // Storage gap for future upgrades
    uint256[36] private __gap;

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

        // Default unstake fees - all set to 0.1% (can be adjusted per-tier if needed)
        unstakeFeeHealthy = 10;   // 0.1%
        unstakeFeeCautious = 10;  // 0.1%
        unstakeFeeCritical = 10;  // 0.1%
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
     * @notice Set the intervention manager address that can trigger interventions
     * @param _interventionManager Address of the InterventionManager contract
     */
    function setInterventionManager(address _interventionManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_interventionManager == address(0)) revert ZeroAddress();
        interventionManager = _interventionManager;
        emit InterventionManagerSet(_interventionManager);
    }

    /**
     * @notice Set unstake fee configuration
     * @dev Fees are in basis points (10000 = 100%). Max 1% (100 bps) per tier.
     * @param _feeHealthy Fee when system is healthy (CR >= 150%)
     * @param _feeCautious Fee when system is cautious (130% <= CR < 150%)
     * @param _feeCritical Fee when system is critical (CR < 130%)
     */
    function setUnstakeFees(
        uint256 _feeHealthy,
        uint256 _feeCautious,
        uint256 _feeCritical
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Max 1% (100 bps) per tier for safety
        if (_feeHealthy > 100 || _feeCautious > 100 || _feeCritical > 100) {
            revert FeeTooHigh();
        }

        unstakeFeeHealthy = _feeHealthy;
        unstakeFeeCautious = _feeCautious;
        unstakeFeeCritical = _feeCritical;

        emit UnstakeFeesUpdated(_feeHealthy, _feeCautious, _feeCritical);
    }

    /**
     * @notice Protocol intervention to convert hzUSD to hzHYPE when CR < 130%
     * @param amountToConvert Amount of hzUSD to convert to hzHYPE
     * @param zhypeReceived Amount of hzHYPE received from conversion
     */
    function protocolIntervention(uint256 amountToConvert, uint256 zhypeReceived) external payable override {
        if (msg.sender != interventionManager) revert InvalidCaller(msg.sender);
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
        if (msg.sender != interventionManager) revert InvalidCaller(msg.sender);

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

    // =============================
    // ===== UNSTAKE FEE LOGIC =====
    // =============================

    /**
     * @notice Get current unstake fee based on system health
     * @dev All tiers currently set to 0.1% - can be adjusted per-tier if needed
     * @return feeBps Current fee in basis points
     */
    function getUnstakeFee() public view returns (uint256 feeBps) {
        // If protocol not set or fees not initialized, return 0
        if (protocol == address(0) || unstakeFeeHealthy == 0) {
            return 0;
        }

        IHypeZionExchange.SystemState state = IHypeZionExchange(protocol).systemState();

        if (state == IHypeZionExchange.SystemState.Normal) {
            return unstakeFeeHealthy;
        } else if (state == IHypeZionExchange.SystemState.Cautious) {
            return unstakeFeeCautious;
        } else {
            return unstakeFeeCritical;
        }
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
     * @notice Applies unstake fee to both stablecoin and levercoin portions
     * @notice Fees are tracked separately for admin collection via collectUnstakeFees()
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

        // Get gross breakdown (before fees)
        uint256 grossStablecoin;
        uint256 grossLevercoin;
        (grossStablecoin, grossLevercoin, totalValue) = this.previewMixedRedeem(shares);

        // Calculate unstake fee
        uint256 feeBps = getUnstakeFee();
        uint256 stablecoinFee = (grossStablecoin * feeBps) / 10000;
        uint256 levercoinFee = (grossLevercoin * feeBps) / 10000;

        // Calculate net amounts after fee
        stablecoinAmount = grossStablecoin - stablecoinFee;
        levercoinAmount = grossLevercoin - levercoinFee;

        // Burn LP tokens
        _burn(msg.sender, shares);

        // Transfer net assets to receiver
        if (stablecoinAmount > 0) {
            IERC20(asset()).transfer(receiver, stablecoinAmount);
        }

        if (levercoinAmount > 0) {
            IERC20(xhype).transfer(receiver, levercoinAmount);
        }

        // Update tracking: deduct gross amounts (net + fee) from pool
        // Fees are tracked separately and do NOT inflate totalAssets/share price
        hzusdInPool -= grossStablecoin;
        hzhypeInPool -= grossLevercoin;
        accumulatedUnstakeFees += stablecoinFee;
        accumulatedUnstakeFeesXHYPE += levercoinFee;

        emit MixedWithdrawn(msg.sender, receiver, stablecoinAmount, levercoinAmount, totalValue, shares);

        // Emit fee event if any fees charged
        uint256 totalFee = stablecoinFee + levercoinFee;
        if (totalFee > 0) {
            emit UnstakeFeeCharged(msg.sender, stablecoinFee, feeBps);
        }
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
     * @dev Override withdraw to track assets and apply unstake fee
     * @notice User specifies net assets to receive; additional shares burned to cover fee
     * @notice Fee is tracked separately and collected by admin via collectUnstakeFees()
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256 shares) {
        // Calculate fee and gross assets needed
        uint256 feeBps = getUnstakeFee();
        uint256 grossAssets;
        uint256 fee;

        if (feeBps > 0) {
            // gross = net * 10000 / (10000 - fee)
            if (feeBps >= 10000) revert FeeTooHigh();
            grossAssets = (assets * 10000) / (10000 - feeBps);
            fee = grossAssets - assets;
        } else {
            grossAssets = assets;
            fee = 0;
        }

        if (grossAssets > totalAssets()) revert InsufficientPoolBalance(grossAssets, totalAssets());

        // Calculate shares needed for gross assets
        shares = previewWithdraw(grossAssets);

        // Handle allowance for non-owner callers
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares
        _burn(owner, shares);

        // Transfer net assets to receiver
        IERC20(asset()).transfer(receiver, assets);

        // Update pool tracking: deduct gross amount (net + fee) from pool
        // Fee is tracked separately and does NOT inflate totalAssets/share price
        hzusdInPool -= grossAssets;
        accumulatedUnstakeFees += fee;

        emit Withdrawn(owner, receiver, assets, shares);
        if (fee > 0) {
            emit UnstakeFeeCharged(owner, fee, feeBps);
        }

        return shares;
    }

    /**
     * @dev Override redeem to track assets and apply unstake fee
     * @notice Fee is charged on withdrawal and tracked separately for admin collection
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

        // Calculate gross assets for the shares
        uint256 grossAssets = previewRedeem(shares);
        if (grossAssets > totalAssets()) revert InsufficientPoolBalance(grossAssets, totalAssets());

        // Calculate and apply unstake fee
        uint256 feeBps = getUnstakeFee();
        uint256 fee = (grossAssets * feeBps) / 10000;
        assets = grossAssets - fee;

        // Handle allowance for non-owner callers
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares
        _burn(owner, shares);

        // Transfer net assets to receiver
        IERC20(asset()).transfer(receiver, assets);

        // Update pool tracking: deduct gross amount (net + fee) from pool
        // Fee is tracked separately and does NOT inflate totalAssets/share price
        hzusdInPool -= grossAssets;
        accumulatedUnstakeFees += fee;

        emit Withdrawn(owner, receiver, assets, shares);
        if (fee > 0) {
            emit UnstakeFeeCharged(owner, fee, feeBps);
        }

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
     * @notice Collect accumulated unstake fees
     * @dev Transfers accumulated hzUSD and hzHYPE fees to the specified recipient
     * @param recipient Address to receive the collected fees
     */
    function collectUnstakeFees(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 hzusdFees = accumulatedUnstakeFees;
        uint256 xhypeFees = accumulatedUnstakeFeesXHYPE;

        if (hzusdFees > 0) {
            accumulatedUnstakeFees = 0;
            IERC20(asset()).transfer(recipient, hzusdFees);
        }
        if (xhypeFees > 0 && xhype != address(0)) {
            accumulatedUnstakeFeesXHYPE = 0;
            IERC20(xhype).transfer(recipient, xhypeFees);
        }

        emit UnstakeFeesCollected(recipient, hzusdFees, xhypeFees);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to owner
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
