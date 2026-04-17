// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../interfaces/IHypeZionExchangeRouter.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IHypeZionVault.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";
import "./HypeZionWithdrawalManagerLibrary.sol";

/**
 * @title HypeZionExchange
 * @notice Core exchange contract for Hylo Protocol on HyperEVM with correct NAV calculations
 * @dev Implements proper pricing based on Hylo's invariant equations with UUPS upgradeability
 */
contract HypeZionExchange is
    IHypeZionExchange,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using HypeZionWithdrawalManagerLibrary for HypeZionWithdrawalManagerLibrary.WithdrawalStorage;

    // ==================
    // === CONSTANTS ====
    // ==================
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    // Collateral ratio thresholds
    uint256 public constant NORMAL_CR_THRESHOLD = 15000; // 150%
    uint256 public constant CAUTIOUS_CR_THRESHOLD = 13000; // 130%
    uint256 public constant EMERGENCY_CR_THRESHOLD = 10000; // 100%

    // Fee configuration (basis points) - removed, moved to state variables

    // NAV and withdrawal
    uint256 public constant INITIAL_ZHYPE_NAV = 1e18; // 1:1 with HYPE
    uint256 public constant MOCK_WITHDRAWAL_DELAY = 30 seconds; // For testing

    // Yield settlement
    uint256 public constant MIN_YIELD_TO_SETTLE = 0.1 ether; // DEPRECATED: was used by removed _settleYieldIfNeeded

    // DEX integration
    address public constant NATIVE_HYPE =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========================
    // === CONTRACT REFS ======
    // ========================
    HzUSD public zusd;
    BullHYPE public zhype;
    IOracle public oracle;
    address public kinetiq; // Kept for storage layout compat; Kinetiq calls now go through Router
    IStabilityPool public stabilityPool;
    IHypeZionVault public hypeZionVault;
    address public dexIntegration; // Deprecated: kept for storage layout compat, use router instead

    // ======================
    // === SYSTEM STATE =====
    // ======================
    IHypeZionExchange.SystemState public systemState;
    bool public swapRedeemPaused;
    string public protocolVersion;

    // =======================
    // === BALANCES & FEES ===
    // =======================
    uint256 public totalHYPECollateral; // Total HYPE staked
    uint256 public totalKHYPEBalance; // Available kHYPE
    uint256 public lockedKHYPEBalance; // kHYPE locked for pending redemptions
    uint256 public accumulatedFees; // Protocol fees accumulated (in kHYPE units)
    uint256 public totalHypeDeposited; // Total deposits (for max limit tracking)

    // ========================
    // === CONFIGURATIONS =====
    // ========================
    IHypeZionExchange.MinimumAmounts public minimumAmounts;
    uint256 public maxTotalDeposit; // Maximum deposit cap

    // DEPRECATED, use _bullHYPEFees and _hzUSDFees
    uint256 public feeHealthy;
    uint256 public feeCautious;
    uint256 public feeCritical;

    // DEPRECATED, use _bullHYPEFees and _hzUSDFees
    uint256 public swapRedeemFeeBps;

    // SwapRedeem configuration - max rate divergenceBps
    uint256 public maxRateDivergenceBps; // Max allowed rate divergence (default: 1000 = 10%)

    // ======================
    // === USER DATA ========
    // ======================
    mapping(address => IHypeZionExchange.UserPosition) public userPositions;

    // ========================
    // === WITHDRAWALS ========
    HypeZionWithdrawalManagerLibrary.WithdrawalStorage private withdrawals;

    // DEPRECATED, use _bullHYPEFees and _hzUSDFees
    uint256 public swapMintFeeBps;

    // Token-specific fees
    IHypeZionExchange.TokenFees internal _bullHYPEFees;
    IHypeZionExchange.TokenFees internal _hzUSDFees;

    // InterventionManager - authorized to perform interventions via this contract
    address public interventionManager;

    // ==================== MULTI-SOURCE ROUTER (v2) ====================
    // New state variables — consuming 3 slots from __gap (46 → 43)

    /// @notice Router contract for multi-source HYPE distribution
    address public router;

    /// @notice Cost basis tracking for secondary yield sources (mirrors totalHYPECollateral for primary)
    uint256 public totalSecondaryCollateral;

    /// @notice Maps Exchange redemptionId → Router secondary ticket ID (0 = no secondary)
    mapping(uint256 => uint256) public redemptionToSecondaryTicket;

    /// @notice Cached kHYPE token address (set via setRouter) — avoids repeated external calls
    address public kHypeToken;

    // Storage gap for future upgrades
    uint256[42] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // Prevent initialization of implementation contract
    }

    /**
     * @notice Receive function to accept HYPE transfers
     * @dev Required for receiving HYPE from Kinetiq during unstaking
     */
    receive() external payable {}

    /**
     * @notice Initialize the exchange with required contracts
     */
    function initialize(
        address _zusd,
        address _zhype,
        address _oracle,
        address _kinetiq,
        address _stabilityPool,
        address _vault,
        address _dexIntegration
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        zusd = HzUSD(_zusd);
        zhype = BullHYPE(_zhype);
        oracle = IOracle(_oracle);
        kinetiq = _kinetiq;
        stabilityPool = IStabilityPool(_stabilityPool);
        hypeZionVault = IHypeZionVault(_vault);
        dexIntegration = _dexIntegration;

        // Note: minimumAmounts, maxTotalDeposit, maxRateDivergenceBps,
        // _bullHYPEFees, _hzUSDFees are configured via setup script
        // (scripts/deploy/09-setup-configuration.js)

        // Initialize withdrawal manager (must be here — sets nextWithdrawalId=1)
        // Note: minimumAmounts, maxTotalDeposit, maxRateDivergenceBps,
        // _bullHYPEFees, _hzUSDFees are configured via setup script
        // (scripts/deploy/09-setup-configuration.js)

        // Initialize withdrawal manager (must be here — sets nextWithdrawalId=1)
        withdrawals.initialize(MOCK_WITHDRAWAL_DELAY);
    }

    // =====================
    // ====== NAV計算 ======
    // =====================


    /**
     * @notice Calculate zUSD NAV in HYPE (zUSD = $1 fixed)
     * @return nav zUSD NAV in HYPE (1e18 scaled)
     */
    function getZusdNavInHYPE() public view returns (uint256 nav) {
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price == 0) revert OraclePriceInvalid();


        // zUSD is $1, so NAV = 1 / HYPE_USD_price
        // nav = (1 USD) / (USD per HYPE) = HYPE
        // Scale to 1e18: nav = 1e18 / hypePrice.price
        nav = (PRECISION * PRECISION) / hypePrice.price;
    }


    /**
     * @notice Calculate total reserves in HYPE (includes locked kHYPE for pending redemptions)
     * @dev Used for CR calculation - must include ALL protocol assets
     * @return Total reserve value in HYPE
     */
    function getTotalReserveInHYPE() public view returns (uint256) {
        uint256 kHypeExchangeRate = _exchangeRate();

        uint256 totalKHYPE = totalKHYPEBalance + lockedKHYPEBalance;
        uint256 primaryReserve = totalKHYPE > 0
            ? (totalKHYPE * kHypeExchangeRate) / PRECISION
            : totalHYPECollateral;

        // Include secondary source reserves if router is configured
        uint256 secondaryReserve = _secondaryReserve();

        return primaryReserve + secondaryReserve;
    }

    /**
     * @notice Get available primary reserve only (excludes locked)
     * @dev Used for proportional split in swapRedeem and queued redeem
     */
    function _getAvailablePrimaryReserveInHYPE()
        internal
        view
        returns (uint256)
    {
        uint256 kHypeExchangeRate = _exchangeRate();
        return
            totalKHYPEBalance > 0
                ? (totalKHYPEBalance * kHypeExchangeRate) / PRECISION
                : 0;
    }


    /**
     * @notice Calculate available reserves in HYPE (excludes locked kHYPE)
     * @dev Used for checking if redemptions can be processed
     * @return Available reserve value in HYPE
     */
    function getAvailableReserveInHYPE() public view returns (uint256) {
        uint256 kHypeExchangeRate = _exchangeRate();

        // Primary: available (not locked) kHYPE
        uint256 primaryAvailable = totalKHYPEBalance > 0
            ? (totalKHYPEBalance * kHypeExchangeRate) / PRECISION
            : 0;

        // Secondary: all reserves (NAV-consistent). Router handles redeemEnabled filtering.
        uint256 secondaryAvailable = _secondaryReserve();

        return primaryAvailable + secondaryAvailable;
    }

    /// @dev Private helper — avoids repeated ABI call encoding at each call site
    function _exchangeRate() private view returns (uint256) {
        return IHypeZionExchangeRouter(router).getExchangeRate();
    }

    function _secondaryReserve() private view returns (uint256) {
        return
            router != address(0)
                ? IHypeZionExchangeRouter(router)
                    .getTotalSecondaryReserveInHYPE()
                : 0;
    }

    /**
     * @notice Calculate zUSD liabilities in HYPE
     * @return Total zUSD liabilities valued in HYPE
     */
    function getZusdLiabilitiesInHYPE() public view returns (uint256) {
        IOracle.PriceData memory priceData = oracle.getPrice("HYPE");
        if (priceData.price == 0) revert OraclePriceInvalid();
        return _getZusdLiabilitiesWithPrice(priceData.price);
    }

    /**
     * @notice Calculate zUSD liabilities using provided HYPE price
     * @param hypePrice HYPE price from oracle
     * @return Total zUSD liabilities valued in HYPE
     */
    function _getZusdLiabilitiesWithPrice(
        uint256 hypePrice
    ) internal view returns (uint256) {
        uint256 zusdSupply = zusd.totalSupply();
        if (zusdSupply == 0) return 0;

        uint256 zusdNav = (PRECISION * PRECISION) / hypePrice;
        uint256 zusdNav = (PRECISION * PRECISION) / hypePrice;
        return (zusdSupply * zusdNav) / PRECISION;
    }


    /**
     * @notice Calculate zHYPE NAV in HYPE using Hylo's invariant
     * @return nav zHYPE NAV in HYPE (1e18 scaled)
     */
    function getZhypeNavInHYPE() public view returns (uint256 nav) {
        uint256 zhypeSupply = zhype.totalSupply();

        // If no zHYPE exists, use initial NAV
        if (zhypeSupply == 0) {
            return INITIAL_ZHYPE_NAV;
        }

        // Get total reserves and liabilities
        uint256 totalReserve = getTotalReserveInHYPE();
        uint256 zusdLiabilities = getZusdLiabilitiesInHYPE();

        // In critical state where reserves don't cover liabilities,
        // zHYPE has no value as all reserves belong to zUSD holders
        // Revert to prevent operations that depend on zHYPE NAV
        if (totalReserve <= zusdLiabilities) {
            revert InsufficientReserve();
        }

        // Variable reserve = Total reserve - zUSD liabilities
        // zHYPE NAV = Variable reserve / zHYPE supply
        uint256 variableReserve = totalReserve - zusdLiabilities;
        nav = (variableReserve * PRECISION) / zhypeSupply;
    }

    /**
     * @notice Calculate szUSD NAV in USD terms
     * @return NAV price (1e18 scaled, e.g., 1.1e18 = $1.10 per share)
     */
    function getSzUSDNavInUSD() public view returns (uint256) {
        return stabilityPool.getSharePrice();
    }

    /**
     * @notice Get kHYPE balance held in vault
     * @return kHYPE amount represented by vault shares
     * @dev Converts exchange's vault shares to underlying kHYPE amount
     */
    function getVaultKHYPEBalance() public view returns (uint256) {
        if (address(hypeZionVault) == address(0)) {
            return 0;
        }

        // Get exchange's vault share balance
        uint256 vaultShares = hypeZionVault.balanceOf(address(this));

        // Convert shares to kHYPE amount (ERC4626 convertToAssets)
        return hypeZionVault.convertToAssets(vaultShares);
    }

    /**
     * @notice Calculate system collateral ratio
     * @return System CR (1e4 scale, 10000 = 100%)
     */
    function getSystemCR() public view returns (uint256) {
        uint256 zusdLiabilities = getZusdLiabilitiesInHYPE();

        // If no liabilities, CR is infinite (return max safe value)
        if (zusdLiabilities == 0) {
            return type(uint256).max;
        }

        uint256 totalReserve = getTotalReserveInHYPE();

        // CR = Reserve / Liabilities * 100%
        // Scale to basis points (10000 = 100%)
        return (totalReserve * BASIS_POINTS) / zusdLiabilities;
    }


    /**
     * @notice Calculate system CR using provided HYPE price
     * @param hypePrice HYPE price from oracle
     * @return System CR (1e4 scale, 10000 = 100%)
     */
    function _getSystemCRWithPrice(
        uint256 hypePrice
    ) internal view returns (uint256) {
        uint256 zusdLiabilities = _getZusdLiabilitiesWithPrice(hypePrice);

        // If no liabilities, CR is infinite (return max safe value)
        if (zusdLiabilities == 0) {
            return type(uint256).max;
        }

        uint256 totalReserve = getTotalReserveInHYPE();

        // CR = Reserve / Liabilities * 100%
        // Scale to basis points (10000 = 100%)
        return (totalReserve * BASIS_POINTS) / zusdLiabilities;
    }

    /**
     * @notice Get fee for a specific token and operation based on current CR
     * @param isZusd True for hzUSD operations, false for bullHYPE operations
     * @param isMint True for mint operations, false for redeem operations
     * @return Fee in basis points
     */
    function getProtocolFee(
        bool isZusd,
        bool isMint
    ) public view returns (uint256) {
        uint256 cr = getSystemCR();
        return _getProtocolFeeWithCR(isZusd, isMint, cr);
    }

    /**
     * @notice Internal fee lookup with cached CR
     * @param isZusd True for hzUSD operations, false for bullHYPE operations
     * @param isMint True for mint operations, false for redeem operations
     * @param cr Current system collateral ratio
     * @return Fee in basis points
     */
    function _getProtocolFeeWithCR(
        bool isZusd,
        bool isMint,
        uint256 cr
    ) internal view returns (uint256) {
        IHypeZionExchange.TokenFees storage fees = isZusd
            ? _hzUSDFees
            : _bullHYPEFees;

        if (isMint) {
            if (cr >= NORMAL_CR_THRESHOLD) return fees.mintHealthy;
            if (cr >= CAUTIOUS_CR_THRESHOLD) return fees.mintCautious;
            return fees.mintCritical;
        } else {
            if (cr >= NORMAL_CR_THRESHOLD) return fees.redeemHealthy;
            if (cr >= CAUTIOUS_CR_THRESHOLD) return fees.redeemCautious;
            return fees.redeemCritical;
            if (cr >= NORMAL_CR_THRESHOLD) return fees.redeemHealthy;
            if (cr >= CAUTIOUS_CR_THRESHOLD) return fees.redeemCautious;
            return fees.redeemCritical;
        }
    }


    // =====================
    // ====== MINTING ======
    // =====================


    /**
     * @notice Mint zHYPE leveraged tokens by staking or swapping HYPE to kHYPE
     * @dev If swapData is empty, uses Kinetiq staking (no slippage, min 5 HYPE, dynamic fee)
     *      If swapData is provided, uses DEX swap (flexible, slippage protected, fixed fee)
     * @param amountHYPE Amount of HYPE to convert
     * @param swapData Encoded swap data from KyberSwap API (empty for Kinetiq staking)
     * @notice Mint zHYPE leveraged tokens by staking or swapping HYPE to kHYPE
     * @dev If swapData is empty, uses Kinetiq staking (no slippage, min 5 HYPE, dynamic fee)
     *      If swapData is provided, uses DEX swap (flexible, slippage protected, fixed fee)
     * @param amountHYPE Amount of HYPE to convert
     * @param swapData Encoded swap data from KyberSwap API (empty for Kinetiq staking)
     * @return zhypeMinted Amount of zHYPE minted
     */
    function mintLevercoin(
        uint256 amountHYPE,
        bytes calldata swapData
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 zhypeMinted)
    {
        if (msg.value != amountHYPE) revert IncorrectHYPEAmount();
        if (amountHYPE < minimumAmounts.mintHypeMin)
            revert BelowMinimumAmount();

        uint256 newTotal = totalHypeDeposited + amountHYPE;
        if (newTotal > maxTotalDeposit)
            revert MaximumDepositExceeded(newTotal, maxTotalDeposit);

        IOracle.PriceData memory priceData = oracle.getPrice("HYPE");
        if (!oracle.isValidPrice(priceData)) revert OraclePriceInvalid();
        uint256 hypePrice = priceData.price;

        uint256 cr = _getSystemCRWithPrice(hypePrice);
        uint256 feeBps = _getProtocolFeeWithCR(false, true, cr);
        uint256 navBefore = getZhypeNavInHYPE();

        (uint256 kHYPEReceived, uint256 secondaryHYPE) = _distributeMint(
            amountHYPE,
            swapData
        );

        uint256 feeKHYPE = (kHYPEReceived * feeBps) / BASIS_POINTS;
        uint256 netKHYPE = kHYPEReceived - feeKHYPE;
        accumulatedFees += feeKHYPE;

        uint256 primaryHypeValue = (netKHYPE * _exchangeRate()) / PRECISION;
        uint256 totalHypeValue = primaryHypeValue + secondaryHYPE;
        zhypeMinted = (totalHypeValue * PRECISION) / navBefore;

        _depositKHYPEToVault(kHYPEReceived);
        totalKHYPEBalance += netKHYPE;
        zhype.mint(msg.sender, zhypeMinted);

        userPositions[msg.sender].hypeCollateral += amountHYPE;
        userPositions[msg.sender].lastUpdateTime = block.timestamp;
        totalHYPECollateral += primaryHypeValue;
        totalHypeDeposited += amountHYPE;

        emit LevercoinMinted(
            msg.sender,
            amountHYPE,
            zhypeMinted,
            (amountHYPE * hypePrice) / PRECISION,
            feeKHYPE
        );
        updateSystemState();
    }

    function mintStablecoin(
        uint256 amountHYPE,
        bytes calldata swapData
    ) external payable nonReentrant whenNotPaused returns (uint256 zusdMinted) {
        if (msg.value != amountHYPE) revert IncorrectHYPEAmount();
        if (amountHYPE < minimumAmounts.mintHypeMin)
            revert BelowMinimumAmount();

        uint256 newTotal = totalHypeDeposited + amountHYPE;
        if (newTotal > maxTotalDeposit)
            revert MaximumDepositExceeded(newTotal, maxTotalDeposit);

        IOracle.PriceData memory priceData = oracle.getPrice("HYPE");
        if (!oracle.isValidPrice(priceData)) revert OraclePriceInvalid();
        uint256 hypePrice = priceData.price;

        uint256 cr = _getSystemCRWithPrice(hypePrice);
        uint256 feeBps = _getProtocolFeeWithCR(true, true, cr);

        (uint256 kHYPEReceived, uint256 secondaryHYPE) = _distributeMint(
            amountHYPE,
            swapData
        );

        uint256 feeKHYPE = (kHYPEReceived * feeBps) / BASIS_POINTS;
        uint256 netKHYPE = kHYPEReceived - feeKHYPE;
        accumulatedFees += feeKHYPE;

        uint256 primaryHypeValue = (netKHYPE * _exchangeRate()) / PRECISION;
        uint256 totalHypeValue = primaryHypeValue + secondaryHYPE;
        zusdMinted = (totalHypeValue * hypePrice) / PRECISION;

        _depositKHYPEToVault(kHYPEReceived);
        totalKHYPEBalance += netKHYPE;
        zusd.mint(msg.sender, zusdMinted);

        userPositions[msg.sender].hypeCollateral += amountHYPE;
        userPositions[msg.sender].lastUpdateTime = block.timestamp;
        totalHYPECollateral += primaryHypeValue;
        totalHypeDeposited += amountHYPE;

        emit StablecoinMinted(
            msg.sender,
            amountHYPE,
            zusdMinted,
            (amountHYPE * hypePrice) / PRECISION,
            feeKHYPE
        );
        updateSystemState();
    }


    // =====================
    // === SYSTEM MGMT =====
    // =====================


    /**
     * @notice Update system state based on current CR
     * @dev Public function - callable by anyone to refresh state
     * @dev Public function - callable by anyone to refresh state
     */
    function updateSystemState() public {
    function updateSystemState() public {
        uint256 cr = getSystemCR();
        IHypeZionExchange.SystemState newState;

        if (cr >= NORMAL_CR_THRESHOLD) {
            newState = IHypeZionExchange.SystemState.Normal;
        } else if (cr >= CAUTIOUS_CR_THRESHOLD) {
            newState = IHypeZionExchange.SystemState.Cautious;
        } else if (cr >= EMERGENCY_CR_THRESHOLD) {
            newState = IHypeZionExchange.SystemState.Critical;
        } else {
            newState = IHypeZionExchange.SystemState.Emergency;
        }

        if (newState != systemState) {
            systemState = newState;
            emit SystemStateChanged(uint8(newState));

            // Emergency state requires special handling
            if (newState == IHypeZionExchange.SystemState.Emergency) {
                emit EmergencyStateActivated(cr);
            }
        }
    }

    /**
     * @notice Get minimum amounts configuration
     */
    function getMinimumAmounts() external view returns (MinimumAmounts memory) {
        return minimumAmounts;
    }

    /**
     * @notice Check rate divergence between Kinetiq and DEX (DOWNSIDE ONLY)
     * @dev Reverts if user would receive significantly LESS than Kinetiq rate suggests
     * @dev Allows unlimited upside - receiving MORE is always beneficial for users
     * @param khypeAmount Amount of kHYPE being swapped
     * @param expectedHype Expected HYPE output (typically user's minHypeOut)
     * @param kinetiqRate Kinetiq exchange rate (kHYPE:HYPE)
     */
    function _checkRateDivergence(
        uint256 khypeAmount,
        uint256 expectedHype,
        uint256 kinetiqRate
    ) internal view {
        if (maxRateDivergenceBps == 0) return;
        if (expectedHype == 0) return;

        uint256 expectedHypeFromKinetiq = (khypeAmount * kinetiqRate) /
            PRECISION;

        if (expectedHype >= expectedHypeFromKinetiq) return;

        uint256 downsideDiff = expectedHypeFromKinetiq - expectedHype;
        uint256 divergenceBps = (downsideDiff * BASIS_POINTS) /
            expectedHypeFromKinetiq;

        if (divergenceBps > maxRateDivergenceBps) {
            revert RateDivergenceTooHigh(divergenceBps, maxRateDivergenceBps);
        }
    }

    /**
     * @notice Distribute HYPE for minting — delegates to Router for Kinetiq + secondary distribution
     * @dev Router handles: primary Kinetiq/DEX staking → transfers kHYPE here, secondary adapter deposits.
     *      Fallback to direct Kinetiq staking when no router is set (backward compat).
     * @param hypeAmount Total HYPE to distribute
     * @param swapData KyberSwap data (empty = Kinetiq stake, non-empty = DEX swap)
     * @return kHYPEReceived kHYPE received for vault deposit
     * @return secondaryDeposited HYPE deposited to secondary adapters
     */
    function _distributeMint(
        uint256 hypeAmount,
        bytes calldata swapData
    ) internal returns (uint256 kHYPEReceived, uint256 secondaryDeposited) {
        if (router == address(0)) revert RouterNotSet();
        (kHYPEReceived, secondaryDeposited) = IHypeZionExchangeRouter(router)
            .distributeDeposit{value: hypeAmount}(swapData);
        totalSecondaryCollateral += secondaryDeposited;
    }

    // =====================
    // ====== REDEEMING ====
    // =====================

    /**
     * @notice Redeem zUSD for HYPE (queues withdrawal)
     * @param zusdAmount Amount of zUSD to redeem
     * @return redemptionId ID of the redemption request
     */
    function redeemStablecoin(
        uint256 zusdAmount
    ) external nonReentrant whenNotPaused returns (uint256 redemptionId) {
        return _executeRedeem(zusdAmount, true);
    }

    /**
     * @notice Redeem zHYPE for HYPE (queues withdrawal)
     * @param zhypeAmount Amount of zHYPE to redeem
     * @return redemptionId ID of the redemption request
     */
    function redeemLevercoin(
        uint256 zhypeAmount
    ) external nonReentrant whenNotPaused returns (uint256 redemptionId) {
        return _executeRedeem(zhypeAmount, false);
    }

    /**
     * @notice Internal function to execute redemption for both zUSD and zHYPE
     * @dev Consolidates common logic to save bytecode
     * @param tokenAmount Amount of zUSD or zHYPE to redeem
     * @param isZusd True for zUSD redemption, false for zHYPE
     * @return redemptionId ID of the redemption request
     */
    function _executeRedeem(
        uint256 tokenAmount,
        bool isZusd
    ) private returns (uint256 redemptionId) {
        // Check minimum amount based on token type
        if (isZusd) {
            if (tokenAmount < minimumAmounts.redeemZusdMin)
                revert BelowMinimumAmount();
        } else {
            if (tokenAmount < minimumAmounts.redeemZhypeMin)
                revert BelowMinimumAmount();
        }

        // Check user has enough tokens
        uint256 userBalance = isZusd
            ? zusd.balanceOf(msg.sender)
            : zhype.balanceOf(msg.sender);
        if (userBalance < tokenAmount)
            revert InsufficientBalance(userBalance, tokenAmount);

        // Combined NAV includes secondary reserves
        uint256 tokenNav = isZusd ? getZusdNavInHYPE() : getZhypeNavInHYPE();

        uint256 grossHypeAmount = (tokenAmount * tokenNav) / PRECISION;
        uint256 feeBps = getProtocolFee(isZusd, false);
        uint256 feeInHype = (grossHypeAmount * feeBps) / BASIS_POINTS;
        uint256 hypeAmount = grossHypeAmount - feeInHype; // net to user (total from all sources)

        // Check combined available reserves
        if (isZusd) {
            uint256 availableReserves = getAvailableReserveInHYPE();
            uint256 zusdLiabilities = getZusdLiabilitiesInHYPE();
            uint256 freeReserves = availableReserves > zusdLiabilities
                ? availableReserves - zusdLiabilities
                : 0;
            if (hypeAmount > freeReserves) {
                revert InsufficientReserves(hypeAmount, freeReserves);
            }
        } else {
            uint256 totalCollateral = totalHYPECollateral +
                totalSecondaryCollateral;
            if (hypeAmount > totalCollateral) {
                revert InsufficientReserves(hypeAmount, totalCollateral);
            }
        }

        // Split between primary and secondary by available reserves
        uint256 primaryAvail = _getAvailablePrimaryReserveInHYPE();
        uint256 secondaryAvail = _secondaryReserve();
        uint256 totalAvail = primaryAvail + secondaryAvail;

        uint256 primaryGrossHype = totalAvail > 0
            ? (grossHypeAmount * primaryAvail) / totalAvail
            : grossHypeAmount;
        uint256 secondaryGrossHype = grossHypeAmount - primaryGrossHype;

        // kHYPE calculations for primary portion
        uint256 exchangeRate = _exchangeRate();
        uint256 grossKHYPE = (primaryGrossHype * PRECISION) / exchangeRate;
        uint256 feeKHYPE = (grossKHYPE * feeBps) / BASIS_POINTS;
        uint256 netKHYPE = grossKHYPE - feeKHYPE;

        // Collect fee (primary only — fee kHYPE stays in vault)
        accumulatedFees += feeKHYPE;

        // Burn tokens from user BEFORE external calls (Checks-Effects-Interactions).
        // Exchange has MINTER_ROLE so can burn directly — no approve needed from user.
        if (isZusd) {
            zusd.burn(msg.sender, tokenAmount);
        } else {
            zhype.burn(msg.sender, tokenAmount);
        }

        // Primary: withdraw net kHYPE and delegate queue to Router → Kinetiq
        _withdrawKHYPEFromVault(netKHYPE);
        IERC20(kHypeToken).safeTransfer(router, netKHYPE);
        uint256 kinetiqWithdrawalId = IHypeZionExchangeRouter(router)
            .queuePrimaryWithdrawal(netKHYPE);

        // Reduce primary cost basis proportionally
        uint256 costBasis = totalKHYPEBalance > 0
            ? (grossKHYPE * totalHYPECollateral) / totalKHYPEBalance
            : 0;
        totalKHYPEBalance -= grossKHYPE;
        lockedKHYPEBalance += netKHYPE;
        _reduceCollateral(costBasis);

        // Secondary: queue withdrawals from router
        uint256 secondaryTicketId = 0;
        if (secondaryGrossHype > 0 && router != address(0)) {
            secondaryTicketId = IHypeZionExchangeRouter(router)
                .queueSecondaryWithdrawals(secondaryGrossHype);
            // Reduce secondary cost basis proportionally
            if (secondaryAvail > 0) {
                uint256 secCostBasis = (secondaryGrossHype *
                    totalSecondaryCollateral) / secondaryAvail;
                if (secCostBasis > totalSecondaryCollateral)
                    secCostBasis = totalSecondaryCollateral;
                totalSecondaryCollateral -= secCostBasis;
            }
        }

        // Expected HYPE = primary net + secondary gross (secondary has no fee)
        uint256 primaryNetHype = primaryGrossHype > feeInHype
            ? primaryGrossHype - feeInHype
            : 0;
        uint256 expectedHypeTotal = primaryNetHype + secondaryGrossHype;

        // Store expectedHypeTotal (user-facing: total HYPE user will receive from all sources)
        redemptionId = withdrawals.queueWithdrawal(
            msg.sender,
            tokenAmount,
            netKHYPE,
            expectedHypeTotal,
            kinetiqWithdrawalId,
            isZusd,
            IHypeZionExchangeRouter(router).getWithdrawalDelay()
        );

        // Store secondary ticket mapping if any
        if (secondaryTicketId != 0) {
            redemptionToSecondaryTicket[redemptionId] = secondaryTicketId;
        }

        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price == 0) revert OraclePriceInvalid();
        uint256 usdValueRedeemed = (expectedHypeTotal * hypePrice.price) /
            PRECISION;

        emit RedemptionQueued(
            msg.sender,
            redemptionId,
            tokenAmount,
            expectedHypeTotal,
            isZusd,
            usdValueRedeemed,
            feeKHYPE
        );

        updateSystemState();

        return redemptionId;
    }

    /**
     * @notice Claim HYPE from a completed redemption request
     * @param redemptionId ID of the redemption to claim
     * @return hypeReceived Amount of HYPE received
     */
    function claimRedemption(
        uint256 redemptionId
    ) external nonReentrant returns (uint256 hypeReceived) {
        // Check primary readiness via Router → Kinetiq
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest
            storage request = withdrawals.requests[redemptionId];
        if (request.requester == address(0)) revert WithdrawalNotReady();

        (bool ready, ) = IHypeZionExchangeRouter(router)
            .isPrimaryWithdrawalReady(request.kinetiqWithdrawalId);

        withdrawals.prepareClaimWithdrawal(redemptionId, msg.sender, ready);

        // Claim from Kinetiq via Router (primary) — 0 is OK when all went to secondary
        hypeReceived = IHypeZionExchangeRouter(router).claimPrimaryWithdrawal(
            request.kinetiqWithdrawalId
        );

        // Claim from secondary sources if a ticket was queued
        // Partial claims are supported: if some sources fail, ticket stays open for re-claim
        uint256 secTicketId = redemptionToSecondaryTicket[redemptionId];
        if (secTicketId != 0 && router != address(0)) {
            try
                IHypeZionExchangeRouter(router).claimSecondaryWithdrawals(
                    secTicketId
                )
            returns (uint256 secHype) {
                hypeReceived += secHype;
            } catch {}
            if (
                IHypeZionExchangeRouter(router).isSecondaryTicketFullyClaimed(
                    secTicketId
                )
            ) {
                delete redemptionToSecondaryTicket[redemptionId];
            }
        }

        // Remove kHYPE from locked balance (was moved to locked when queued)
        lockedKHYPEBalance -= request.khypeAmount;

        // Fee was already collected as kHYPE at redeem time — no withholding needed

        // Fee was already collected as kHYPE at redeem time — no withholding needed
        // Tokens were already burned at queue time in _executeRedeem — no burn needed here.

        // Transfer total HYPE (primary + secondary) to user
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert HYPETransferFailed();

        // Update user position and totals
        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        // Note: totalHYPECollateral and totalHypeDeposited were already reduced
        // at queue time in _executeRedeem (when kHYPE left the vault).
        // Note: totalHYPECollateral and totalHypeDeposited were already reduced
        // at queue time in _executeRedeem (when kHYPE left the vault).

        // Mark withdrawal as claimed using library
        withdrawals.markWithdrawalClaimed(redemptionId, hypeReceived);

        // Calculate USD value claimed
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price == 0) revert OraclePriceInvalid();
        uint256 usdValueClaimed = (hypeReceived * hypePrice.price) / PRECISION;

        emit RedemptionClaimed(
            msg.sender,
            redemptionId,
            hypeReceived,
            usdValueClaimed
        );

        // Update system state
        updateSystemState();
        updateSystemState();

        return hypeReceived;
    }

    /**
     * @notice Re-claim pending secondary withdrawals for a previously claimed redemption
     * @dev Used when claimRedemption succeeded for primary but some secondary sources were
     *      temporarily unavailable. User calls this after the source recovers.
     * @param redemptionId ID of the already-claimed redemption with pending secondary
     * @return hypeReceived Additional HYPE received from previously-pending sources
     */
    function reclaimPendingSecondary(
        uint256 redemptionId
    ) external nonReentrant returns (uint256 hypeReceived) {
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest
            storage request = withdrawals.requests[redemptionId];
        if (request.requester != msg.sender) revert NotYourRedemption();

        uint256 secTicketId = redemptionToSecondaryTicket[redemptionId];
        if (secTicketId == 0) revert WithdrawalNotReady();

        hypeReceived = IHypeZionExchangeRouter(router)
            .claimSecondaryWithdrawals(secTicketId);

        if (
            IHypeZionExchangeRouter(router).isSecondaryTicketFullyClaimed(
                secTicketId
            )
        ) {
            delete redemptionToSecondaryTicket[redemptionId];
        }

        if (hypeReceived > 0) {
            (bool success, ) = payable(msg.sender).call{value: hypeReceived}(
                ""
            );
            if (!success) revert HYPETransferFailed();
        }

        emit SecondaryReClaimed(msg.sender, redemptionId, hypeReceived);
    }

    /**
     * @notice Get user's pending redemption IDs
     * @param user Address of the user
     * @return ids Array of redemption IDs
     */
    function getUserRedemptions(
        address user
    ) external view returns (uint256[] memory) {
        return withdrawals.getUserWithdrawals(user);
    }

    // ===========================
    // === SWAPREDEM FUNCTIONS ===
    // ===========================

    /**
     * @notice Instant redemption of zUSD for HYPE via DEX swap
     * @dev Burns zUSD, swaps kHYPE → HYPE via DEX, applies 5% fee
     * @param zusdAmount Amount of zUSD to redeem
     * @param encodedSwapData Encoded swap data from KyberSwap API
     * @param minHypeOut Minimum HYPE to receive (slippage protection)
     * @return hypeReceived Net HYPE received by user (after fee)
     */
    function swapRedeemStablecoin(
        uint256 zusdAmount,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) external nonReentrant whenNotPaused returns (uint256 hypeReceived) {
        return
            _executeSwapRedeem(zusdAmount, true, encodedSwapData, minHypeOut);
    }

    /**
     * @notice Instant redemption of zHYPE for HYPE via DEX swap
     * @dev Burns zHYPE, swaps kHYPE → HYPE via DEX, applies 5% fee
     * @param zhypeAmount Amount of zHYPE to redeem
     * @param encodedSwapData Encoded swap data from KyberSwap API.
     *        Format: abi.encode(primarySwapData, secondarySwapData) when secondary DEX swap needed,
     *        or raw KyberSwap calldata for backward compatibility (no secondary swap).
     * @param minHypeOut Minimum HYPE to receive (slippage protection)
     * @return hypeReceived Net HYPE received by user (after fee)
     */
    function swapRedeemLevercoin(
        uint256 zhypeAmount,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) external nonReentrant whenNotPaused returns (uint256 hypeReceived) {
        return
            _executeSwapRedeem(zhypeAmount, false, encodedSwapData, minHypeOut);
    }

    /**
     * @notice Internal function to execute SwapRedeem for both zUSD and zHYPE
     * @dev Consolidates common logic to save bytecode.
     *      encodedSwapData can be either:
     *      - abi.encode(bytes primarySwapData, bytes secondarySwapData) — new format with secondary DEX swap
     *      - Raw KyberSwap calldata — backward compatible, no secondary swap
     * @param tokenAmount Amount of zUSD or zHYPE to redeem
     * @param isZusd True for zUSD redemption, false for zHYPE
     * @param encodedSwapData Encoded swap data (see format above)
     * @param minHypeOut Minimum HYPE to receive (slippage protection)
     * @return hypeReceived Net HYPE received by user (after fee)
     */
    function _executeSwapRedeem(
        uint256 tokenAmount,
        bool isZusd,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) private returns (uint256) {
        // Check if SwapRedeem is paused
        if (swapRedeemPaused) revert SwapRedeemPaused();

        // Check minimum amount based on token type
        if (isZusd) {
            if (tokenAmount < minimumAmounts.redeemZusdMin)
                revert BelowMinimumAmount();
        } else {
            if (tokenAmount < minimumAmounts.redeemZhypeMin)
                revert BelowMinimumAmount();
        }

        // Router must be set — handles DEX swap and secondary withdrawal
        if (router == address(0)) revert RouterNotSet();

        // Check user has enough tokens
        uint256 userBalance = isZusd
            ? zusd.balanceOf(msg.sender)
            : zhype.balanceOf(msg.sender);
        if (userBalance < tokenAmount)
            revert InsufficientBalance(userBalance, tokenAmount);

        // Combined NAV (includes secondary via getTotalReserveInHYPE)
        uint256 tokenNav = isZusd ? getZusdNavInHYPE() : getZhypeNavInHYPE();
        uint256 hypeEquivalent = (tokenAmount * tokenNav) / PRECISION;
        uint256 exchangeRate = _exchangeRate();

        // Split between primary and secondary by available reserves
        uint256 primaryAvail = _getAvailablePrimaryReserveInHYPE();
        uint256 secondaryAvail = _secondaryReserve();
        uint256 totalAvail = primaryAvail + secondaryAvail;

        uint256 primaryPortion = totalAvail > 0
            ? (hypeEquivalent * primaryAvail) / totalAvail
            : hypeEquivalent;
        uint256 secondaryPortion = hypeEquivalent - primaryPortion;

        // kHYPE calculations for primary portion only
        uint256 khypeNeeded = (primaryPortion * PRECISION) / exchangeRate;
        uint256 feeBps = getProtocolFee(isZusd, false);
        uint256 feeKHYPE = (khypeNeeded * feeBps) / BASIS_POINTS;
        uint256 netKHYPE = khypeNeeded - feeKHYPE;

        // Cap primary to available kHYPE (rounding from cap can cause khypeNeeded to slightly exceed balance)
        if (khypeNeeded > totalKHYPEBalance) {
            khypeNeeded = totalKHYPEBalance;
            feeKHYPE = (khypeNeeded * feeBps) / BASIS_POINTS;
            netKHYPE = khypeNeeded - feeKHYPE;
        }

        // Rate divergence check on primary kHYPE portion (skip when no primary)
        if (netKHYPE > 0) {
            _checkRateDivergence(netKHYPE, minHypeOut, exchangeRate);
        }

        // Collect fee (primary only)
        accumulatedFees += feeKHYPE;

        // Burn tokens from user
        if (isZusd) {
            zusd.burn(msg.sender, tokenAmount);
        } else {
            zhype.burn(msg.sender, tokenAmount);
        }

        // Decode swap data: try abi.decode(primarySwapData, secondarySwapData) first,
        // fall back to treating entire payload as primarySwapData (backward compatible)
        bytes memory primarySwapData;
        bytes memory secondarySwapData;
        if (encodedSwapData.length > 0) {
            // Try to decode as (bytes, bytes). ABI-encoded bytes tuple starts with offset pointers
            // at positions 0x00 and 0x20. If first word == 0x40 (offset to first bytes), it's the new format.
            if (encodedSwapData.length >= 64) {
                uint256 firstWord = uint256(bytes32(encodedSwapData[0:32]));
                if (firstWord == 0x40) {
                    // New format: abi.encode(primarySwapData, secondarySwapData)
                    (primarySwapData, secondarySwapData) = abi.decode(
                        encodedSwapData,
                        (bytes, bytes)
                    );
                } else {
                    primarySwapData = encodedSwapData;
                }
            } else {
                primarySwapData = encodedSwapData;
            }
        }

        // Delegate both DEX swap and secondary withdrawal to Router
        uint256 hypeReceived;
        if (netKHYPE > 0) {
            _withdrawKHYPEFromVault(netKHYPE);
            IERC20(kHypeToken).safeTransfer(router, netKHYPE);
            hypeReceived = IHypeZionExchangeRouter(router).swapKHYPEForHYPE(
                netKHYPE,
                primarySwapData,
                secondaryPortion,
                secondarySwapData,
                minHypeOut
            );
        } else {
            // All reserves in secondary — skip DEX swap, only withdraw from adapters
            hypeReceived = IHypeZionExchangeRouter(router).swapKHYPEForHYPE(
                0,
                "",
                secondaryPortion,
                secondarySwapData,
                minHypeOut
            );
        }

        if (hypeReceived < minHypeOut)
            revert InsufficientOutput(hypeReceived, minHypeOut);

        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (!oracle.isValidPrice(hypePrice)) revert OraclePriceInvalid();

        // Reduce primary cost basis proportionally
        if (khypeNeeded > 0) {
            uint256 costBasis = totalKHYPEBalance > 0
                ? (khypeNeeded * totalHYPECollateral) / totalKHYPEBalance
                : 0;
            totalKHYPEBalance -= khypeNeeded;
            _reduceCollateral(costBasis);
        }

        // Reduce secondary cost basis proportionally
        if (secondaryPortion > 0 && secondaryAvail > 0) {
            uint256 secCostBasis = (secondaryPortion *
                totalSecondaryCollateral) / secondaryAvail;
            if (secCostBasis > totalSecondaryCollateral)
                secCostBasis = totalSecondaryCollateral;
            totalSecondaryCollateral -= secCostBasis;
        }

        // Transfer total HYPE to user
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert HYPETransferFailed();

        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        emit SwapRedeemExecuted(
            msg.sender,
            isZusd ? 0 : 1,
            tokenAmount,
            netKHYPE,
            hypeReceived,
            feeKHYPE,
            (hypeEquivalent * hypePrice.price) / PRECISION
        );

        updateSystemState();

        return hypeReceived;
    }

    /**
     * @notice Check if a redemption is ready to claim
     * @param redemptionId ID of the redemption to check
     * @return ready True if ready to claim (queried from Kinetiq)
     * @return timeRemaining Always 0 (Kinetiq doesn't provide time remaining)
     */
    function isRedemptionReady(
        uint256 redemptionId
    ) external view returns (bool ready, uint256 timeRemaining) {
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest
            memory req = withdrawals.requests[redemptionId];
        bool isPrimaryReady;
        if (req.kinetiqWithdrawalId != 0) {
            (isPrimaryReady, ) = IHypeZionExchangeRouter(router)
                .isPrimaryWithdrawalReady(req.kinetiqWithdrawalId);
        }
        (ready, timeRemaining) = withdrawals.isWithdrawalReady(
            redemptionId,
            isPrimaryReady
        );
        if (!ready) return (false, timeRemaining);

        // Also check secondary ticket readiness if any
        uint256 secTicketId = redemptionToSecondaryTicket[redemptionId];
        if (secTicketId != 0 && router != address(0)) {
            if (
                !IHypeZionExchangeRouter(router).isSecondaryTicketReady(
                    secTicketId
                )
            ) {
                return (false, 0);
            }
        }

        return (true, 0);
    }

    /**
     * @notice Get withdrawal request details
     * @param redemptionId ID of the redemption
     * @return requester Address of requester
     * @return tokenAmount Amount of tokens to be burned
     * @return expectedHype Expected HYPE amount
     * @return isZusd True if zUSD redemption, false if zHYPE
     * @return state Current state of withdrawal
     */
    function getRedemptionDetails(
        uint256 redemptionId
    )
        external
        view
        returns (
            address requester,
            uint256 tokenAmount,
            uint256 expectedHype,
            bool isZusd,
            uint8 state
        )
    {
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest
            memory request = withdrawals.requests[redemptionId];
        return (
            request.requester,
            request.tokenAmount,
            request.expectedHype,
            request.isZusd,
            uint8(request.state)
        );
    }

    // =====================
    // === ADMIN FUNCTIONS =
    // =====================


    /**
     * @notice Collect accumulated fees and send to specified recipient
     * @param recipient Address to receive the collected kHYPE fees
     * @notice Collect accumulated fees and send to specified recipient
     * @param recipient Address to receive the collected kHYPE fees
     */
    function collectFees(
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        uint256 fees = accumulatedFees;
        if (fees == 0) revert AmountMustBeGreaterThanZero();
        if (fees == 0) revert AmountMustBeGreaterThanZero();
        accumulatedFees = 0;

        // Withdraw fee kHYPE from vault and send to recipient
        _withdrawKHYPEFromVault(fees);
        address khypeToken = kHypeToken;
        IERC20(khypeToken).safeTransfer(recipient, fees);

        emit FeesCollected(recipient, fees);
        emit FeesCollected(recipient, fees);
    }

    /**
     * @notice Set the protocol version (owner only)
     * @param version New version string
     */
    function setProtocolVersion(
        string calldata version
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        protocolVersion = version;
    }

    /**
     * @notice Settle pending yield if available before redemption
     * @dev Called internally before redemptions to ensure NAV is current
     * @return yieldSettled Amount of yield that was settled (in HYPE)
     */
    /**
     * @notice Pause protocol (owner only)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }


    /**
     * @notice Unpause protocol (owner only)
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency pause/unpause for SwapRedeem functionality
     * @dev Only callable by admin for emergency situations
     * @param paused True to pause SwapRedeem, false to unpause
     */
    function setSwapRedeemPaused(
        bool paused
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        swapRedeemPaused = paused;
        emit SwapRedeemPausedStateChanged(paused);
    }

    /**
     * @notice Internal helper to deposit kHYPE to vault
     * @param khypeAmount Amount of kHYPE to deposit
     * @dev Called automatically after receiving kHYPE from Kinetiq staking
     */
    function _depositKHYPEToVault(uint256 khypeAmount) internal {
        if (address(hypeZionVault) == address(0)) revert VaultNotSet();
        if (khypeAmount == 0) return; // No kHYPE to deposit (all went to secondary sources)

        // Get kHYPE token address
        address khypeToken = kHypeToken;

        // Approve vault to spend kHYPE (if not already approved)
        uint256 currentAllowance = IERC20(khypeToken).allowance(
            address(this),
            address(hypeZionVault)
        );
        if (currentAllowance < khypeAmount) {
            IERC20(khypeToken).approve(
                address(hypeZionVault),
                type(uint256).max
            );
        }

        // Deposit to vault (receive vault shares in return)
        hypeZionVault.deposit(khypeAmount, address(this));

        // Note: totalKHYPEBalance remains the same (we still own the kHYPE, just via vault shares)
        // No accounting changes needed here - vault shares represent our kHYPE ownership
    }

    /**
     * @notice Internal helper to withdraw kHYPE from vault
     * @param khypeAmount Amount of kHYPE needed
     * @return actualReceived Actual kHYPE amount received from vault
     * @dev Called before redemptions or swaps to get kHYPE
     */
    function _withdrawKHYPEFromVault(
        uint256 khypeAmount
    ) internal returns (uint256 actualReceived) {
        if (address(hypeZionVault) == address(0)) revert VaultNotSet();
        if (khypeAmount == 0) return 0; // No kHYPE to withdraw (all in secondary sources)

        // Get kHYPE balance before withdrawal
        address khypeToken = kHypeToken;
        uint256 balanceBefore = IERC20(khypeToken).balanceOf(address(this));

        // Calculate shares needed for the kHYPE amount
        // Use previewWithdraw to get exact shares needed
        uint256 sharesNeeded = hypeZionVault.previewWithdraw(khypeAmount);

        // Withdraw from vault (burn shares, receive kHYPE)
        hypeZionVault.redeem(sharesNeeded, address(this), address(this));

        // Verify actual received amount
        uint256 balanceAfter = IERC20(khypeToken).balanceOf(address(this));
        actualReceived = balanceAfter - balanceBefore;

        if (actualReceived < khypeAmount)
            revert InsufficientBalance(khypeAmount, actualReceived);

        return actualReceived;
    }

    /**
     * @notice Withdraw kHYPE for yield harvesting - updates accounting to prevent NAV inflation
     * @dev Only callable by YieldManager. Transfers kHYPE to caller (YieldManager) for DEX swap.
     * @param kHypeAmount Amount of kHYPE to withdraw
     */
    function withdrawKHYPEForYield(uint256 kHypeAmount) external {
        if (msg.sender != IHypeZionExchangeRouter(router).getYieldManager())
            revert RouterNotSet();
        _withdrawKHYPEFromVault(kHypeAmount);
        totalKHYPEBalance -= kHypeAmount;
        // Transfer to YieldManager (caller) instead of Kinetiq - for DEX-based yield flow
        IERC20(kHypeToken).safeTransfer(msg.sender, kHypeAmount);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to owner
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Saturating subtraction of hypeAmount from totalHYPECollateral and totalHypeDeposited.
     */
    function _reduceCollateral(uint256 hypeAmount) internal {
        totalHYPECollateral = totalHYPECollateral >= hypeAmount
            ? totalHYPECollateral - hypeAmount
            : 0;
        totalHypeDeposited = totalHypeDeposited >= hypeAmount
            ? totalHypeDeposited - hypeAmount
            : 0;
    }

    // ==============================
    // === MINIMUM CONFIG MGMT ======
    // ==============================

    /**
     * @notice Set new minimum amounts for all actions
     * @param _mintHypeMin Minimum HYPE for minting
     * @param _redeemZusdMin Minimum zUSD for redemption
     * @param _redeemZhypeMin Minimum zHYPE for redemption
     * @param _swapZusdMin Minimum zUSD for swaps
     * @param _swapZhypeMin Minimum zHYPE for swaps
     */
    function setMinimumAmounts(
        uint256 _mintHypeMin,
        uint256 _redeemZusdMin,
        uint256 _redeemZhypeMin,
        uint256 _swapZusdMin,
        uint256 _swapZhypeMin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumAmounts = MinimumAmounts({
            mintHypeMin: _mintHypeMin,
            redeemZusdMin: _redeemZusdMin,
            redeemZhypeMin: _redeemZhypeMin,
            swapZusdMin: _swapZusdMin,
            swapZhypeMin: _swapZhypeMin
        });

        emit MinimumAmountsUpdated(
            _mintHypeMin,
            _redeemZusdMin,
            _redeemZhypeMin,
            _swapZusdMin,
            _swapZhypeMin
        );
    }

    /**
     * @notice Set maximum deposit limits
     * @param _maxTotalDeposit Maximum total HYPE that can be deposited system-wide
     */
    function setMaximumLimits(
        uint256 _maxTotalDeposit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTotalDeposit = _maxTotalDeposit;
        emit MaximumLimitsUpdated(_maxTotalDeposit);
    }

    // ================================
    // === INTERVENTION FUNCTIONS =====
    // ================================

    /// @notice Set the InterventionManager address
    /**
     * @notice Set the Router address for multi-source HYPE distribution
     * @dev Set to address(0) to disable multi-source (100% Kinetiq primary)
     * @param _router HypeZionExchangeRouter proxy address
     */
    function setRouter(address _router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        router = _router;
        if (_router != address(0)) {
            kHypeToken = IHypeZionExchangeRouter(_router).getKHypeAddress();
        }
    }

    function setInterventionManager(
        address _im
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_im == address(0)) revert InvalidAddress();
        emit InterventionManagerUpdated(interventionManager, _im);
        interventionManager = _im;
    }

    /// @notice Burn tokens for intervention (only InterventionManager)
    function interventionBurn(
        address from,
        uint256 amount,
        bool isZusd
    ) external {
        if (msg.sender != interventionManager) revert UnauthorizedAccess();
        if (isZusd) zusd.burn(from, amount);
        else zhype.burn(from, amount);
    }

    /// @notice Mint tokens for intervention (only InterventionManager)
    function interventionMint(
        address to,
        uint256 amount,
        bool isZusd
    ) external {
        if (msg.sender != interventionManager) revert UnauthorizedAccess();
        if (isZusd) zusd.mint(to, amount);
        else zhype.mint(to, amount);
    }

    // ========================
    // === V3 FEE SETTERS =====
    // ========================

    /**
     * @notice Set token-specific fee configuration for both bullHYPE and hzUSD
     * @param bullHypeMintFees bullHYPE mint fees [healthy, cautious, critical] in basis points
     * @param bullHypeRedeemFees bullHYPE redeem fees [healthy, cautious, critical] in basis points
     * @param hzUsdMintFees hzUSD mint fees [healthy, cautious, critical] in basis points
     * @param hzUsdRedeemFees hzUSD redeem fees [healthy, cautious, critical] in basis points
     */
    function setTokenFees(
        uint16[3] calldata bullHypeMintFees,
        uint16[3] calldata bullHypeRedeemFees,
        uint16[3] calldata hzUsdMintFees,
        uint16[3] calldata hzUsdRedeemFees
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // bullHYPE: Mint max 10%, Redeem max 15%
        if (
            bullHypeMintFees[0] > 1000 ||
            bullHypeMintFees[1] > 1000 ||
            bullHypeMintFees[2] > 1000
        ) revert FeeTooHigh();
        if (
            bullHypeRedeemFees[0] > 1500 ||
            bullHypeRedeemFees[1] > 1500 ||
            bullHypeRedeemFees[2] > 1500
        ) revert FeeTooHigh();
        // hzUSD: Mint and redeem max 10%
        if (
            hzUsdMintFees[0] > 1000 ||
            hzUsdMintFees[1] > 1000 ||
            hzUsdMintFees[2] > 1000
        ) revert FeeTooHigh();
        if (
            hzUsdRedeemFees[0] > 1000 ||
            hzUsdRedeemFees[1] > 1000 ||
            hzUsdRedeemFees[2] > 1000
        ) revert FeeTooHigh();

        _bullHYPEFees = IHypeZionExchange.TokenFees({
            mintHealthy: bullHypeMintFees[0],
            mintCautious: bullHypeMintFees[1],
            mintCritical: bullHypeMintFees[2],
            redeemHealthy: bullHypeRedeemFees[0],
            redeemCautious: bullHypeRedeemFees[1],
            redeemCritical: bullHypeRedeemFees[2]
        });

        _hzUSDFees = IHypeZionExchange.TokenFees({
            mintHealthy: hzUsdMintFees[0],
            mintCautious: hzUsdMintFees[1],
            mintCritical: hzUsdMintFees[2],
            redeemHealthy: hzUsdRedeemFees[0],
            redeemCautious: hzUsdRedeemFees[1],
            redeemCritical: hzUsdRedeemFees[2]
        });

        emit TokenFeesUpdated(
            bullHypeMintFees,
            bullHypeRedeemFees,
            hzUsdMintFees,
            hzUsdRedeemFees
        );
    }

    // ========================
    // === V3 FEE GETTERS =====
    // ========================

    /**
     * @notice Get bullHYPE fee configuration
     * @return TokenFees struct with all fee values
     */
    function bullHYPEFees()
        external
        view
        returns (IHypeZionExchange.TokenFees memory)
    {
        return _bullHYPEFees;
    }

    /**
     * @notice Get hzUSD fee configuration
     * @return TokenFees struct with all fee values
     */
    function hzUSDFees()
        external
        view
        returns (IHypeZionExchange.TokenFees memory)
    {
        return _hzUSDFees;
    }
}

