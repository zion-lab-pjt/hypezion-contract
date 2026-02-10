// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IDexIntegration.sol";
import "../core/HypeZionExchange.sol";

/**
 * @title KinetiqYieldManager
 * @notice Manages yield harvesting and compounding from kHYPE staking following Hylo's economic model
 * @dev Harvests kHYPE yield and compounds to StabilityPool as hzUSD
 *      - Staked hzUSD holders receive 100% of yield
 *      - xHYPE holders receive 0% yield (pure leverage exposure)
 *      - Harvest/compound functions are restricted to OPERATOR_ROLE
 *      - All validation logic is in the contract
 *      - UUPS upgradeable pattern
 *
 * V2 Changes (DEX-based flow):
 *      - Removed 2-step queue/claim flow (old Kinetiq unstaking)
 *      - New single-step harvestAndCompound() using DEX swaps
 *      - No waiting period (instant DEX swaps)
 *      - Lower minimum harvest amount (0.01 HYPE vs 5 HYPE)
 */
contract KinetiqYieldManager is AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Kinetiq integration contract (for exchange rate queries)
    IKinetiqIntegration public kinetiqIntegration;

    // Protocol integration
    address payable public hypeZionExchange;
    address public stabilityPool;

    // @deprecated - kept for storage layout compatibility
    struct WithdrawalRequest {
        uint256 withdrawalId;
        uint256 kHypeAmount;
        uint256 hypeAmount;
        uint256 queuedAt;
        bool claimed;
    }
    WithdrawalRequest[] internal pendingWithdrawals; // @deprecated
    mapping(uint256 => uint256) internal withdrawalIdToIndex; // @deprecated

    // NAV tracking
    struct NAVSnapshot {
        uint256 khypeBalance;
        uint256 hypeValue;
        uint256 exchangeRate; // kHYPE to HYPE rate (18 decimals)
        uint256 timestamp;
        uint256 yieldAccrued;
    }

    // Historical NAV snapshots
    NAVSnapshot[] public navHistory;
    mapping(uint256 => NAVSnapshot) public navSnapshots; // timestamp => snapshot

    // Yield distribution
    uint256 public totalYieldHarvested;
    uint256 public lastHarvestTimestamp;
    uint256 public lastCompoundTimestamp;
    uint256 public harvestInterval; // @deprecated - kept for storage layout compatibility

    // NAV thresholds and alerts
    uint256 public constant MIN_NAV_RATIO = 1e18; // 1.0 (kHYPE should never be worth less than HYPE)
    uint256 public navAlertThreshold;

    IDexIntegration public dexIntegration;
    uint256 public minHarvestAmount;

    // Native token address used by KyberSwap
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Pending harvested HYPE waiting for compound step
    uint256 public pendingHarvestedHype;

    // Storage gap for future upgrades
    uint256[46] private __gap;

    // Events
    event NAVUpdated(uint256 indexed timestamp, uint256 khypeBalance, uint256 hypeValue, uint256 exchangeRate);
    event YieldHarvested(uint256 indexed timestamp, uint256 yieldAmount, address indexed harvester);
    event NAVAlert(uint256 indexed timestamp, uint256 currentRate, uint256 expectedRate);
    event NAVAlertThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event HypeZionExchangeSet(address indexed exchange);
    event StabilityPoolSet(address indexed pool);
    event YieldCompounded(uint256 kHypeHarvested, uint256 hypeReceived, uint256 hzusdMinted, uint256 timestamp);
    event DexIntegrationSet(address indexed dexIntegration);
    event MinHarvestAmountSet(uint256 amount);
    event YieldHarvestedToStorage(uint256 kHypeHarvested, uint256 hypeReceived, uint256 timestamp);

    // Errors
    error InvalidNAV();
    error NoYieldToHarvest();
    error NAVBelowMinimum();
    error InvalidThreshold();
    error InvalidAddress();
    error OnlyExchange();
    error YieldTooSmall();
    error InsufficientRemaining();
    error SwapFailed();
    error MintFailed();
    error NoPendingHype();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during deployment through proxy
     * @param _kinetiqIntegration Address of KinetiqIntegration contract
     */
    function initialize(address _kinetiqIntegration) public initializer {
        require(_kinetiqIntegration != address(0), "Invalid Kinetiq address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        kinetiqIntegration = IKinetiqIntegration(_kinetiqIntegration);

        // Set default values
        navAlertThreshold = 95e16; // 0.95 - alert if NAV drops below 95% of expected
        minHarvestAmount = 0.01 ether;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Receive HYPE from DEX swaps and other sources
     * @dev Accept HYPE from any source. This contract doesn't hold user funds,
     *      so there's no security risk from receiving HYPE from unknown sources.
     */
    receive() external payable {}

    /**
     * @notice Helper: Calculate total HYPE value of collateral kHYPE (excludes protocol fees)
     * @dev Uses totalKHYPEBalance (accounting balance) instead of physical vault balance
     *      to exclude accumulatedFees kHYPE from yield calculations.
     * @return Total HYPE value (collateral kHYPE × exchange rate)
     */
    function _getTotalHYPEValue() internal view returns (uint256) {
        uint256 collateralKHYPE = HypeZionExchange(hypeZionExchange).totalKHYPEBalance();
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
        return (collateralKHYPE * exchangeRate) / 1e18;
    }

    /**
     * @notice Update NAV snapshot from vault
     * @dev Fetches current exchange rate and balances from vault
     */
    function updateNAV() external onlyRole(OPERATOR_ROLE) {
        // Use accounting balance (excludes fee kHYPE) for accurate NAV tracking
        uint256 khypeBalance = HypeZionExchange(hypeZionExchange).totalKHYPEBalance();
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();

        if (exchangeRate < MIN_NAV_RATIO) revert NAVBelowMinimum();

        uint256 hypeValue = (khypeBalance * exchangeRate) / 1e18;

        if (exchangeRate < MIN_NAV_RATIO * navAlertThreshold / 1e18) {
            emit NAVAlert(block.timestamp, exchangeRate, MIN_NAV_RATIO);
        }

        uint256 yieldAccrued = 0;
        if (navHistory.length > 0) {
            NAVSnapshot memory lastSnapshot = navHistory[navHistory.length - 1];
            if (hypeValue > lastSnapshot.hypeValue) {
                yieldAccrued = hypeValue - lastSnapshot.hypeValue;
            }
        }

        NAVSnapshot memory snapshot = NAVSnapshot({
            khypeBalance: khypeBalance,
            hypeValue: hypeValue,
            exchangeRate: exchangeRate,
            timestamp: block.timestamp,
            yieldAccrued: yieldAccrued
        });

        navHistory.push(snapshot);
        navSnapshots[block.timestamp] = snapshot;

        emit NAVUpdated(block.timestamp, khypeBalance, hypeValue, exchangeRate);
    }

    /**
     * @notice Calculate current yield available for harvesting in HYPE terms
     * @dev Yield = Current HYPE value - Original deposits (from Exchange)
     * @return yieldInHYPE Amount of HYPE yield available
     */
    function calculateYield() public view returns (uint256 yieldInHYPE) {
        uint256 currentValue = _getTotalHYPEValue();
        uint256 totalUserDeposits = HypeZionExchange(hypeZionExchange).totalHYPECollateral();

        if (currentValue > totalUserDeposits) {
            yieldInHYPE = currentValue - totalUserDeposits;
        } else {
            yieldInHYPE = 0;
        }
    }

    /**
     * @notice Calculate current yield available for harvesting in kHYPE terms
     * @dev Converts HYPE yield to kHYPE using exchange rate
     * @return yieldInKHYPE Amount of kHYPE yield available
     */
    function calculateYieldInKHYPE() public view returns (uint256 yieldInKHYPE) {
        uint256 yieldInHYPE = calculateYield();
        if (yieldInHYPE == 0) return 0;

        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
        yieldInKHYPE = (yieldInHYPE * 1e18) / exchangeRate;
    }

    /**
     * @notice Harvest yield (Step 1): Swap kHYPE to HYPE and store for later compound
     * @dev Restricted to OPERATOR_ROLE.
     *      Flow: Withdraw kHYPE from vault to Swap kHYPE to HYPE via DEX to Store HYPE
     *      Call compound() separately with fresh swap data for exact HYPE amount.
     *
     * @param kHypeToHypeSwapData Encoded swap data from KyberSwap API (kHYPE to HYPE)
     * @return hypeReceived Amount of HYPE received and stored for compound
     */
    function harvest(
        bytes calldata kHypeToHypeSwapData
    ) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 hypeReceived) {
        // 1. Calculate yield in kHYPE
        uint256 yieldInKHYPE = calculateYieldInKHYPE();
        if (yieldInKHYPE == 0) revert NoYieldToHarvest();

        // 2. Check minimum harvest amount
        if (yieldInKHYPE < minHarvestAmount) revert YieldTooSmall();

        // 3. Safety check: ensure remaining covers 100% redemption
        uint256 currentValue = _getTotalHYPEValue();
        uint256 totalUserDeposits = HypeZionExchange(hypeZionExchange).totalHYPECollateral();
        uint256 yieldInHYPE = calculateYield();
        uint256 remainingValue = currentValue - yieldInHYPE;
        if (remainingValue < totalUserDeposits) revert InsufficientRemaining();

        // 4. Withdraw kHYPE from vault via Exchange (transfers kHYPE to this contract)
        HypeZionExchange(hypeZionExchange).withdrawKHYPEForYield(yieldInKHYPE);

        // 5. Get kHYPE token address
        address kHypeToken = kinetiqIntegration.getKHypeAddress();

        // 6. Swap kHYPE to HYPE via DexIntegration
        // Transfer kHYPE to DexIntegration first (DexIntegration expects tokens to be present)
        IERC20(kHypeToken).safeTransfer(address(dexIntegration), yieldInKHYPE);

        // Execute swap: kHYPE to HYPE
        hypeReceived = dexIntegration.executeSwap(
            kHypeToHypeSwapData,
            kHypeToken,           // tokenIn: kHYPE
            NATIVE_TOKEN,         // tokenOut: HYPE (native)
            yieldInKHYPE,         // amountIn
            0,                    // minAmountOut (handled by swap data)
            address(this)         // recipient
        );

        if (hypeReceived == 0) revert SwapFailed();

        // 7. Store HYPE for compound step (add to any existing pending amount)
        pendingHarvestedHype += hypeReceived;

        // 8. Update harvest tracking
        lastHarvestTimestamp = block.timestamp;

        emit YieldHarvestedToStorage(yieldInKHYPE, hypeReceived, block.timestamp);
        return hypeReceived;
    }

    /**
     * @notice Compound stored HYPE (Step 2): Mint hzUSD and compound to StabilityPool
     * @dev Restricted to OPERATOR_ROLE.
     *      Flow: Use stored HYPE to Mint hzUSD to Compound to StabilityPool
     *      Requires harvest() to be called first.
     *
     * @param hypeToKHypeSwapData Encoded swap data from KyberSwap API (HYPE to kHYPE for minting)
     * @return hzusdMinted Amount of hzUSD minted and compounded
     */
    function compound(
        bytes calldata hypeToKHypeSwapData
    ) external nonReentrant onlyRole(OPERATOR_ROLE) returns (uint256 hzusdMinted) {
        // 1. Check we have pending HYPE to compound
        uint256 hypeAmount = pendingHarvestedHype;
        if (hypeAmount == 0) revert NoPendingHype();

        // 2. Clear pending amount before external calls (CEI pattern)
        pendingHarvestedHype = 0;

        // 3. Mint hzUSD from HYPE (includes HYPE to kHYPE swap inside mintStablecoin)
        require(hypeZionExchange != address(0), "Exchange not set");
        HypeZionExchange exchange = HypeZionExchange(payable(hypeZionExchange));
        hzusdMinted = exchange.mintStablecoin{value: hypeAmount}(hypeAmount, hypeToKHypeSwapData);
        if (hzusdMinted == 0) revert MintFailed();

        // 4. Transfer hzUSD to StabilityPool
        address hzusd = address(exchange.zusd());
        require(hzusd != address(0), "HzUSD not set");
        require(stabilityPool != address(0), "StabilityPool not set");

        bool success = IERC20(hzusd).transfer(stabilityPool, hzusdMinted);
        require(success, "HzUSD transfer failed");

        // 5. Compound into StabilityPool (increases NAV without minting shares)
        IStabilityPool(stabilityPool).compoundYield(hzusdMinted);

        // 6. Update tracking
        totalYieldHarvested += hypeAmount;
        lastCompoundTimestamp = block.timestamp;

        emit YieldCompounded(0, hypeAmount, hzusdMinted, block.timestamp);
        return hzusdMinted;
    }

    /**
     * @notice Set NAV alert threshold
     * @param newThreshold New threshold (18 decimals, e.g., 0.95e18 for 95%)
     */
    function setNAVAlertThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0 || newThreshold > 1e18) revert InvalidThreshold();

        uint256 oldThreshold = navAlertThreshold;
        navAlertThreshold = newThreshold;

        emit NAVAlertThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Check if harvest is available and worthwhile
     * @return canHarvestNow Whether harvest can be performed
     * @return yieldAmount Current yield available in kHYPE
     */
    function canHarvest() external view returns (bool canHarvestNow, uint256 yieldAmount) {
        yieldAmount = calculateYieldInKHYPE();
        canHarvestNow = yieldAmount >= minHarvestAmount;
    }

    /**
     * @notice Set HypeZionExchange address
     * @param _exchange Address of HypeZionExchange contract
     */
    function setHypeZionExchange(address _exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_exchange == address(0)) revert InvalidAddress();
        hypeZionExchange = payable(_exchange);
        emit HypeZionExchangeSet(_exchange);
    }

    /**
     * @notice Set StabilityPool address
     * @param _pool Address of StabilityPool contract
     */
    function setStabilityPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pool == address(0)) revert InvalidAddress();
        stabilityPool = _pool;
        emit StabilityPoolSet(_pool);
    }

    /**
     * @notice Set DEX integration contract address
     * @param _dexIntegration Address of DexIntegration contract
     */
    function setDexIntegration(address _dexIntegration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dexIntegration == address(0)) revert InvalidAddress();
        dexIntegration = IDexIntegration(_dexIntegration);
        emit DexIntegrationSet(_dexIntegration);
    }

    /**
     * @notice Set minimum harvest amount
     * @param _amount Minimum kHYPE amount required to harvest
     */
    function setMinHarvestAmount(uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minHarvestAmount = _amount;
        emit MinHarvestAmountSet(_amount);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to admin
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
