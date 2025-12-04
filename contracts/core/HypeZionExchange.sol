// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IHypeZionVault.sol";
import "../interfaces/IDexIntegration.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";
import "./HypeZionWithdrawalManagerLibrary.sol";

/**
 * @title HypeZionExchange
 * @notice Core exchange contract for Hylo Protocol on HyperEVM with correct NAV calculations
 * @dev Implements proper pricing based on Hylo's invariant equations with UUPS upgradeability
 */
contract HypeZionExchange is IHypeZionExchange, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using HypeZionWithdrawalManagerLibrary for HypeZionWithdrawalManagerLibrary.WithdrawalStorage;

    // ==================
    // === CONSTANTS ====
    // ==================
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    // Collateral ratio thresholds
    uint256 public constant NORMAL_CR_THRESHOLD = 15000;     // 150%
    uint256 public constant CAUTIOUS_CR_THRESHOLD = 13000;   // 130%
    uint256 public constant EMERGENCY_CR_THRESHOLD = 10000;  // 100%

    // Fee configuration (basis points) - removed, moved to state variables

    // NAV and withdrawal
    uint256 public constant INITIAL_ZHYPE_NAV = 1e18;           // 1:1 with HYPE
    uint256 public constant MOCK_WITHDRAWAL_DELAY = 30 seconds; // For testing

    // Yield settlement
    uint256 public constant MIN_YIELD_TO_SETTLE = 0.1 ether;    // Minimum 0.1 HYPE worth of yield

    // DEX integration
    address public constant NATIVE_HYPE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========================
    // === CONTRACT REFS ======
    // ========================
    HzUSD public zusd;
    BullHYPE public zhype;
    IOracle public oracle;
    IKinetiqIntegration public kinetiq;
    IStabilityPool public stabilityPool;
    IHypeZionVault public hypeZionVault;
    IDexIntegration public dexIntegration;

    // ======================
    // === SYSTEM STATE =====
    // ======================
    IHypeZionExchange.SystemState public systemState;
    bool public swapRedeemPaused;
    string public protocolVersion;

    // =======================
    // === BALANCES & FEES ===
    // =======================
    uint256 public totalHYPECollateral;   // Total HYPE staked
    uint256 public totalKHYPEBalance;     // Available kHYPE
    uint256 public lockedKHYPEBalance;    // kHYPE locked for pending redemptions
    uint256 public accumulatedFees;       // Protocol fees accumulated (in ZUSD units)
    uint256 public totalHypeDeposited;    // Total deposits (for max limit tracking)

    // ========================
    // === CONFIGURATIONS =====
    // ========================
    IHypeZionExchange.MinimumAmounts public minimumAmounts;
    uint256 public maxTotalDeposit;  // Maximum deposit cap

    // Fee configuration (basis points) - admin configurable
    uint256 public feeHealthy;                // 0.3% when CR >= 150% (default: 30)
    uint256 public feeCautious;               // 0.2% when 130% <= CR < 150% (default: 20)
    uint256 public feeCritical;               // 0.1% when CR < 130% (default: 10)

    // SwapRedeem configuration - admin configurable
    uint256 public swapRedeemFeeBps;          // Fee for swap redeem operations (default: 500 = 5%)
    uint256 public maxRateDivergenceBps;      // Max allowed rate divergence (default: 1000 = 10%)

    // ======================
    // === USER DATA ========
    // ======================
    mapping(address => IHypeZionExchange.UserPosition) public userPositions;

    // ========================
    // === WITHDRAWALS ========
    // ========================
    HypeZionWithdrawalManagerLibrary.WithdrawalStorage private withdrawals;

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap;

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
        kinetiq = IKinetiqIntegration(_kinetiq);
        stabilityPool = IStabilityPool(_stabilityPool);
        hypeZionVault = IHypeZionVault(_vault);
        dexIntegration = IDexIntegration(_dexIntegration);

        // Initialize state variables
        systemState = IHypeZionExchange.SystemState.Normal;

        // Initialize minimum amounts (testnet defaults - 0.01 for all)
        minimumAmounts = MinimumAmounts({
            mintHypeMin: 0.01 ether,      // 0.01 HYPE for testing
            redeemZusdMin: 0.01 ether,    // 0.01 zUSD for testing
            redeemZhypeMin: 0.01 ether,   // 0.01 zHYPE for testing
            swapZusdMin: 0.01 ether,      // 0.01 zUSD for testing
            swapZhypeMin: 0.01 ether      // 0.01 zHYPE for testing
        });

        // Initialize maximum limits (testnet defaults - 1M HYPE cap)
        maxTotalDeposit = 1_000_000 ether;  // 1M HYPE system-wide deposit cap for testing
        totalHypeDeposited = 0;  // Start with no deposits

        // Initialize fee configuration (default values)
        feeHealthy = 30;                  // 0.3% when CR >= 150%
        feeCautious = 20;                 // 0.2% when 130% <= CR < 150%
        feeCritical = 10;                 // 0.1% when CR < 130%

        // Initialize swap redeem configuration
        swapRedeemFeeBps = 500;           // 5% fee
        maxRateDivergenceBps = 1000;      // 10% max divergence

        // Initialize withdrawal manager
        withdrawals.initialize(MOCK_WITHDRAWAL_DELAY);
    }

    // =====================
    // ====== NAV ======
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
        uint256 kHypeExchangeRate = kinetiq.getExchangeRate();

        uint256 totalKHYPE = totalKHYPEBalance + lockedKHYPEBalance;
        uint256 hypeFromStaking = totalKHYPE > 0 ?
            (totalKHYPE * kHypeExchangeRate) / PRECISION :
            totalHYPECollateral;

        return hypeFromStaking;
    }
    
    /**
     * @notice Calculate available reserves in HYPE (excludes locked kHYPE)
     * @dev Used for checking if redemptions can be processed
     * @return Available reserve value in HYPE
     */
    function getAvailableReserveInHYPE() public view returns (uint256) {
        // Get kHYPE exchange rate from Kinetiq
        uint256 kHypeExchangeRate = kinetiq.getExchangeRate();

        // Only use available kHYPE balance (not locked)
        uint256 availableHypeFromStaking = totalKHYPEBalance > 0 ?
            (totalKHYPEBalance * kHypeExchangeRate) / PRECISION :
            0;

        return availableHypeFromStaking;
    }

    /**
     * @notice Calculate zUSD liabilities in HYPE
     * @return Total zUSD liabilities valued in HYPE
     */
    function getZusdLiabilitiesInHYPE() public view returns (uint256) {
        uint256 zusdSupply = zusd.totalSupply();
        if (zusdSupply == 0) return 0;

        uint256 zusdNav = getZusdNavInHYPE();
        // liabilities = zusd_supply * zusd_nav_in_hype
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
     * @notice Get current fee based on system CR
     * @return fee in basis points
     */
    function getCurrentFee() public view returns (uint256) {
        uint256 cr = getSystemCR();

        if (cr >= NORMAL_CR_THRESHOLD) {
            return feeHealthy;  // Healthy mode
        } else if (cr >= CAUTIOUS_CR_THRESHOLD) {
            return feeCautious; // Cautious mode
        } else {
            return feeCritical; // Critical mode
        }
    }

    
    // =====================
    // ====== MINTING ======
    // =====================
    
    /**
     * @notice Mint zHYPE leveraged tokens by staking HYPE
     * @param amountHYPE Amount of HYPE to stake
     * @return zhypeMinted Amount of zHYPE minted
     */
    function mintLevercoin(uint256 amountHYPE) external payable nonReentrant whenNotPaused returns (uint256 zhypeMinted) {
        if (msg.value != amountHYPE) revert IncorrectHYPEAmount();

        // Check our protocol minimum
        if (amountHYPE < minimumAmounts.mintHypeMin) revert BelowMinimumAmount();

        // Also check Kinetiq minimum (if different)
        uint256 kinetiqMin = kinetiq.getMinStakingAmount();
        if (amountHYPE < kinetiqMin) {
            revert MinimumStakingAmountNotMet(amountHYPE, kinetiqMin);
        }

        // Check maximum total deposit limit
        uint256 newTotal = totalHypeDeposited + amountHYPE;
        if (newTotal > maxTotalDeposit) {
            revert MaximumDepositExceeded(newTotal, maxTotalDeposit);
        }

        // Calculate pre-deposit NAV
        uint256 navBefore = getZhypeNavInHYPE();
        uint256 zusdNav = getZusdNavInHYPE();

        // Get current fee based on CR
        uint256 feeBps = getCurrentFee();

        // Calculate minted amount at pre-deposit NAV
        // minted = deposit / nav * (1 - fee)
        zhypeMinted = (amountHYPE * PRECISION) / navBefore;
        uint256 fee = (zhypeMinted * feeBps) / BASIS_POINTS;
        zhypeMinted -= fee;

        // Convert fee to ZUSD using NAV ratio (fee in zHYPE -> HYPE -> ZUSD)
        if (fee > 0 && zusdNav > 0) {
            uint256 feeInZusd = (fee * navBefore) / zusdNav;
            accumulatedFees += feeInZusd;
        }

        // Stake HYPE through Kinetiq (sending actual HYPE)
        uint256 kHYPEReceived = kinetiq.stakeHYPE{value: amountHYPE}(amountHYPE);
        totalKHYPEBalance += kHYPEReceived;

        // Immediately deposit kHYPE to vault for yield earning
        _depositKHYPEToVault(kHYPEReceived);

        // Mint zHYPE to user
        zhype.mint(msg.sender, zhypeMinted);
        
        // Update user position - only track collateral and timestamp
        userPositions[msg.sender].hypeCollateral += amountHYPE;
        userPositions[msg.sender].lastUpdateTime = block.timestamp;
        
        // Update total collateral
        totalHYPECollateral += amountHYPE;

        // Track total deposits for maximum limit enforcement
        totalHypeDeposited += amountHYPE;
        emit DepositTracked(msg.sender, amountHYPE, totalHypeDeposited);

        // Calculate USD value invested using the same price used for NAV
        // Since NAV = 1/price for zUSD, we can derive: price = 1/zusdNav
        uint256 usdValueInvested = (PRECISION * PRECISION) / zusdNav; // This gives us HYPE price in USD
        usdValueInvested = (amountHYPE * usdValueInvested) / PRECISION;

        emit LevercoinMinted(msg.sender, amountHYPE, zhypeMinted, usdValueInvested);
        
        // Check and update system state
        _updateSystemState();
        
        return zhypeMinted;
    }
    
    /**
     * @notice Mint zUSD stablecoin by staking HYPE
     * @param amountHYPE Amount of HYPE to stake
     * @return zusdMinted Amount of zUSD minted
     */
    function mintStablecoin(uint256 amountHYPE) external payable nonReentrant whenNotPaused returns (uint256 zusdMinted) {
        if (msg.value != amountHYPE) revert IncorrectHYPEAmount();

        // Check our protocol minimum
        if (amountHYPE < minimumAmounts.mintHypeMin) revert BelowMinimumAmount();

        // Also check Kinetiq minimum (if different)
        uint256 kinetiqMin = kinetiq.getMinStakingAmount();
        if (amountHYPE < kinetiqMin) {
            revert MinimumStakingAmountNotMet(amountHYPE, kinetiqMin);
        }

        // Check maximum total deposit limit
        uint256 newTotal = totalHypeDeposited + amountHYPE;
        if (newTotal > maxTotalDeposit) {
            revert MaximumDepositExceeded(newTotal, maxTotalDeposit);
        }

        // Get HYPE price for USD value calculation
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (!oracle.isValidPrice(hypePrice)) revert OraclePriceInvalid();

        // Calculate zUSD amount (1 zUSD = $1)
        zusdMinted = (amountHYPE * hypePrice.price) / PRECISION;

        // Apply protocol fee based on CR
        uint256 feeBps = getCurrentFee();
        uint256 fee = (zusdMinted * feeBps) / BASIS_POINTS;
        zusdMinted -= fee;
        accumulatedFees += fee;
        
        // Stake HYPE through Kinetiq (sending actual HYPE)
        uint256 kHYPEReceived = kinetiq.stakeHYPE{value: amountHYPE}(amountHYPE);
        totalKHYPEBalance += kHYPEReceived;

        // Immediately deposit kHYPE to vault for yield earning
        _depositKHYPEToVault(kHYPEReceived);

        // Mint zUSD to user
        zusd.mint(msg.sender, zusdMinted);
        
        // Update user position - only track collateral and timestamp
        userPositions[msg.sender].hypeCollateral += amountHYPE;
        userPositions[msg.sender].lastUpdateTime = block.timestamp;
        
        // Update total collateral
        totalHYPECollateral += amountHYPE;

        // Track total deposits for maximum limit enforcement
        totalHypeDeposited += amountHYPE;
        emit DepositTracked(msg.sender, amountHYPE, totalHypeDeposited);

        // Calculate USD value invested (using existing hypePrice from line 413)
        uint256 usdValueInvested = (amountHYPE * hypePrice.price) / PRECISION;

        emit StablecoinMinted(msg.sender, amountHYPE, zusdMinted, usdValueInvested);
        
        // Check and update system state
        _updateSystemState();
        
        return zusdMinted;
    }
    
    // =====================
    // === SYSTEM MGMT =====
    // =====================
    
    /**
     * @notice Update system state based on current CR
     */
    function _updateSystemState() internal {
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

        emit CollateralRatioUpdated(cr);
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

        uint256 expectedHypeFromKinetiq = (khypeAmount * kinetiqRate) / PRECISION;

        if (expectedHype >= expectedHypeFromKinetiq) return;

        uint256 downsideDiff = expectedHypeFromKinetiq - expectedHype;
        uint256 divergenceBps = (downsideDiff * BASIS_POINTS) / expectedHypeFromKinetiq;

        if (divergenceBps > maxRateDivergenceBps) {
            revert RateDivergenceTooHigh(divergenceBps, maxRateDivergenceBps);
        }
    }

    /**
     * @notice Calculate minimum output with slippage tolerance
     * @param amount Input amount
     * @param slippageBps Slippage tolerance in basis points (e.g., 50 = 0.5%)
     * @return minOut Minimum acceptable output after slippage
     * @dev Helper function for calculating slippage protection
     */
    function _calculateMinOut(uint256 amount, uint256 slippageBps) internal pure returns (uint256 minOut) {
        if (slippageBps > BASIS_POINTS) revert InvalidSlippage();
        minOut = (amount * (BASIS_POINTS - slippageBps)) / BASIS_POINTS;
    }

    /// @notice Internal swap for protocol interventions (bypasses critical state restrictions)
    /// @dev Burns HzUSD from stability pool and mints hzHYPE to stability pool
    /// @param zusdAmount Amount of HzUSD to convert from stability pool
    /// @return zhypeAmount Amount of hzHYPE minted to stability pool
    function _protocolInterventionSwap(uint256 zusdAmount)
        internal
        returns (uint256 zhypeAmount)
    {
        uint256 zhypeSupply = zhype.totalSupply();
        uint256 zusdNav = getZusdNavInHYPE();

        // If no zhype exists yet, mint at initial NAV maintaining value equivalence
        if (zhypeSupply == 0) {
            // @audit-fix: Must consider zusdNav to maintain value equivalence
            // Value burned (in HYPE) = zusdAmount * zusdNav
            // zhypeAmount = value_burned / INITIAL_ZHYPE_NAV
            zhypeAmount = (zusdAmount * zusdNav) / INITIAL_ZHYPE_NAV;
        } else {
            // Calculate zHYPE to mint maintaining value equivalence
            // Formula: (zusdAmount * zusdNav * current_zhype_supply) / (PRECISION * current_zhype_equity)
            uint256 current_liabilities_in_HYPE = getZusdLiabilitiesInHYPE();
            uint256 current_reserves_in_HYPE = getTotalReserveInHYPE();
            uint256 current_zhype_equity = current_reserves_in_HYPE - current_liabilities_in_HYPE;

            // Value of minted zhype = value of burned zusd
            // Convert zusdAmount tokens to HYPE value, then to zhype tokens
            zhypeAmount = (zusdAmount * zusdNav * zhypeSupply) / (PRECISION * current_zhype_equity);
        }

        // Burn HzUSD from stability pool (decreases liability)
        zusd.burn(address(stabilityPool), zusdAmount);

        // Mint hzHYPE to stability pool (increases equity)
        zhype.mint(address(stabilityPool), zhypeAmount);

        emit ProtocolIntervention(zusdAmount, zhypeAmount, getSystemCR());
    }

    /**
     * @notice Trigger protocol intervention to restore CR to 130%
     * @dev Automatically calculates and converts HzUSD from stability pool to restore CR to 130%
     * @dev Permissionless - anyone can call when CR < 130%
     * @return zhypeMinted Amount of hzHYPE minted during intervention
     */
    function triggerIntervention()
        external
        returns (uint256 zhypeMinted)
    {
        uint256 cr = getSystemCR();

        // Block intervention in Emergency state - would make things worse
        if (systemState == IHypeZionExchange.SystemState.Emergency) {
            revert EmergencyModeActive();
        }

        if (cr >= CAUTIOUS_CR_THRESHOLD) revert CRNotLowEnough();

        // Calculate exact amount needed to restore CR to 130%
        // Formula: current_liabilities_in_HYPE - current_reserves_in_HYPE/1.3
        uint256 current_reserves_in_HYPE = getTotalReserveInHYPE();
        uint256 current_liabilities_in_HYPE = getZusdLiabilitiesInHYPE();

        // Liability reduction needed to reach 130% CR
        uint256 liabilityReduction = current_liabilities_in_HYPE - (current_reserves_in_HYPE * BASIS_POINTS) / CAUTIOUS_CR_THRESHOLD;

        // Convert liability reduction (in HYPE) to zusd tokens to burn
        // zusdTokens = liabilityReduction / zusdNav
        uint256 zusdNav = getZusdNavInHYPE();
        uint256 zusdTokensToBurn = (liabilityReduction * PRECISION) / zusdNav;

        // Validate amount doesn't exceed available assets in stability pool
        uint256 availableForIntervention = zusd.balanceOf(address(stabilityPool));
        if (zusdTokensToBurn > availableForIntervention) {
            revert InsufficientInterventionAssets(zusdTokensToBurn, availableForIntervention);
        }

        // Perform internal swap: burn HzUSD tokens, mint hzHYPE
        // This function also emits ProtocolIntervention event
        zhypeMinted = _protocolInterventionSwap(zusdTokensToBurn);

        // Update stability pool's internal accounting
        stabilityPool.protocolIntervention(zusdTokensToBurn, zhypeMinted);

        // Update system state after intervention
        _updateSystemState();
    }

    /**
     * @notice Exit recovery mode when CR becomes healthy (≥150%)
     * @dev Converts hzHYPE back to hzUSD in stability pool, restoring single-asset state
     * @dev Permissionless - anyone can call when CR ≥ 150% and pool has hzHYPE
     * @param minZusdOut Minimum zUSD to mint (0 for no slippage protection)
     */
    function exitRecoveryMode(uint256 minZusdOut) external nonReentrant {
        uint256 crBefore = getSystemCR();

        if (crBefore < NORMAL_CR_THRESHOLD) {
            revert CRNotLowEnough();
        }

        uint256 zhypeInPool = stabilityPool.hzhypeInPool();
        if (zhypeInPool == 0) {
            revert InvalidAmount(0);
        }

        // Calculate equivalent zUSD amount using current NAV values
        // Formula: zusdAmount = zhypeInPool × zhypeNav / zusdNav
        uint256 zhypeNav = getZhypeNavInHYPE();
        uint256 zusdNav = getZusdNavInHYPE();

        if (zusdNav == 0) revert InvalidNAV();

        uint256 zusdToMint = (zhypeInPool * zhypeNav) / zusdNav;

        if (minZusdOut > 0 && zusdToMint < minZusdOut) {
            revert InsufficientBalance(zusdToMint, minZusdOut);
        }

        zhype.burn(address(stabilityPool), zhypeInPool);
        zusd.mint(address(stabilityPool), zusdToMint);
        stabilityPool.exitRecoveryMode(zhypeInPool, zusdToMint);
        _updateSystemState();

        uint256 crAfter = getSystemCR();
        if (crAfter < NORMAL_CR_THRESHOLD) {
            revert CRDroppedBelowThreshold(crAfter, NORMAL_CR_THRESHOLD);
        }

        emit RecoveryModeExited(zhypeInPool, zusdToMint, zhypeNav, zusdNav, crAfter);
    }

    // =====================
    // ====== REDEEMING ====
    // =====================

    /**
     * @notice Redeem zUSD for HYPE (queues withdrawal)
     * @param zusdAmount Amount of zUSD to redeem
     * @return redemptionId ID of the redemption request
     */
    function redeemStablecoin(uint256 zusdAmount) external nonReentrant whenNotPaused returns (uint256 redemptionId) {
        return _executeRedeem(zusdAmount, true);
    }

    /**
     * @notice Redeem zHYPE for HYPE (queues withdrawal)
     * @param zhypeAmount Amount of zHYPE to redeem
     * @return redemptionId ID of the redemption request
     */
    function redeemLevercoin(uint256 zhypeAmount) external nonReentrant whenNotPaused returns (uint256 redemptionId) {
        return _executeRedeem(zhypeAmount, false);
    }

    /**
     * @notice Internal function to execute redemption for both zUSD and zHYPE
     * @dev Consolidates common logic to save bytecode
     * @param tokenAmount Amount of zUSD or zHYPE to redeem
     * @param isZusd True for zUSD redemption, false for zHYPE
     * @return redemptionId ID of the redemption request
     */
    function _executeRedeem(uint256 tokenAmount, bool isZusd) private returns (uint256 redemptionId) {
        // NEW: Settle yield before redemption to ensure accurate NAV
        _settleYieldIfNeeded();

        // Check minimum amount based on token type
        if (isZusd) {
            if (tokenAmount < minimumAmounts.redeemZusdMin) revert BelowMinimumAmount();
        } else {
            if (tokenAmount < minimumAmounts.redeemZhypeMin) revert BelowMinimumAmount();
        }

        // Check user has enough tokens
        uint256 userBalance = isZusd ? zusd.balanceOf(msg.sender) : zhype.balanceOf(msg.sender);
        if (userBalance < tokenAmount) revert InsufficientBalance(userBalance, tokenAmount);

        // Get token NAV
        uint256 tokenNav = isZusd ? getZusdNavInHYPE() : getZhypeNavInHYPE();

        // Calculate HYPE amount to return
        uint256 hypeAmount = (tokenAmount * tokenNav) / PRECISION;

        // Apply redemption fee
        uint256 feeBps = getCurrentFee();
        uint256 fee = (hypeAmount * feeBps) / BASIS_POINTS;
        hypeAmount -= fee;

        // Convert fee to ZUSD (fee in HYPE -> ZUSD)
        if (fee > 0) {
            uint256 zusdNav = getZusdNavInHYPE();
            if (zusdNav > 0) {
                uint256 feeInZusd = (fee * PRECISION) / zusdNav;
                accumulatedFees += feeInZusd;
            }
        }

        // Check reserves (different logic for zUSD vs zHYPE)
        if (isZusd) {
            uint256 availableReserves = getAvailableReserveInHYPE();
            uint256 zusdLiabilities = getZusdLiabilitiesInHYPE();
            uint256 freeReserves = availableReserves > zusdLiabilities ?
                availableReserves - zusdLiabilities : 0;
            if (hypeAmount > freeReserves) {
                revert InsufficientReserves(hypeAmount, freeReserves);
            }
        } else {
            if (hypeAmount > totalHYPECollateral) {
                revert InsufficientReserves(hypeAmount, totalHYPECollateral);
            }
        }

        // Calculate kHYPE amount needed
        uint256 exchangeRate = kinetiq.getExchangeRate();
        uint256 khypeAmount = (hypeAmount * PRECISION) / exchangeRate;

        // Lock tokens from user BEFORE external calls (Checks-Effects-Interactions pattern)
        if (isZusd) {
            zusd.transferFrom(msg.sender, address(this), tokenAmount);
        } else {
            zhype.transferFrom(msg.sender, address(this), tokenAmount);
        }

        // Withdraw kHYPE from Vault and transfer to Kinetiq
        _withdrawKHYPEFromVault(khypeAmount);
        address khypeToken = kinetiq.getKHypeAddress();
        IERC20(khypeToken).safeTransfer(address(kinetiq), khypeAmount);

        // Queue unstaking from Kinetiq
        uint256 kinetiqWithdrawalId = kinetiq.queueUnstakeHYPE(khypeAmount);

        // Move kHYPE from available to locked
        totalKHYPEBalance -= khypeAmount;
        lockedKHYPEBalance += khypeAmount;

        // Queue withdrawal
        redemptionId = withdrawals.queueWithdrawal(
            msg.sender,
            tokenAmount,
            khypeAmount,
            hypeAmount,
            kinetiqWithdrawalId,
            isZusd,
            kinetiq
        );

        // Update user position
        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        // Calculate USD value
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price == 0) revert OraclePriceInvalid();
        uint256 usdValueRedeemed = (hypeAmount * hypePrice.price) / PRECISION;

        emit RedemptionQueued(msg.sender, redemptionId, tokenAmount, hypeAmount, isZusd, usdValueRedeemed);

        // Update system state
        _updateSystemState();

        return redemptionId;
    }

    /**
     * @notice Claim HYPE from a completed redemption request
     * @param redemptionId ID of the redemption to claim
     * @return hypeReceived Amount of HYPE received
     */
    function claimRedemption(uint256 redemptionId) external nonReentrant returns (uint256 hypeReceived) {
        // Use library to validate and get withdrawal details
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest storage request = withdrawals.prepareClaimWithdrawal(
            redemptionId,
            msg.sender,
            kinetiq
        );

        // Check if Kinetiq withdrawal is ready
        (bool ready, uint256 expectedHype) = kinetiq.isUnstakeReady(request.kinetiqWithdrawalId);
        if (!ready) revert WithdrawalNotReady();
        if (expectedHype < request.expectedHype * 99 / 100) revert AmountMismatch(); // Allow 1% variance

        // Claim from Kinetiq
        hypeReceived = kinetiq.claimUnstake(request.kinetiqWithdrawalId);
        if (hypeReceived == 0) revert NoHYPEReceived();

        // Remove kHYPE from locked balance (was moved to locked when queued)
        lockedKHYPEBalance -= request.khypeAmount;

        // NOW burn the locked tokens (after successfully receiving HYPE)
        if (request.isZusd) {
            // Burn zUSD that was locked in contract
            zusd.burn(address(this), request.tokenAmount);
        } else {
            // Burn zHYPE that was locked in contract
            zhype.burn(address(this), request.tokenAmount);
        }

        // Transfer HYPE to user
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert HYPETransferFailed();

        // Update user position and totals
        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        // Use saturating subtraction to prevent accounting drift
        totalHYPECollateral = totalHYPECollateral >= hypeReceived ?
            totalHYPECollateral - hypeReceived : 0;

        // Decrease total deposits to allow new deposits after redemptions
        totalHypeDeposited = totalHypeDeposited >= hypeReceived ?
            totalHypeDeposited - hypeReceived : 0;

        // Mark withdrawal as claimed using library
        withdrawals.markWithdrawalClaimed(redemptionId, hypeReceived);

        // Calculate USD value claimed
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price == 0) revert OraclePriceInvalid();
        uint256 usdValueClaimed = (hypeReceived * hypePrice.price) / PRECISION;

        emit RedemptionClaimed(msg.sender, redemptionId, hypeReceived, usdValueClaimed);

        // Update system state
        _updateSystemState();

        return hypeReceived;
    }


    /**
     * @notice Get user's pending redemption IDs
     * @param user Address of the user
     * @return ids Array of redemption IDs
     */
    function getUserRedemptions(address user) external view returns (uint256[] memory) {
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
        return _executeSwapRedeem(zusdAmount, true, encodedSwapData, minHypeOut);
    }

    /**
     * @notice Instant redemption of zHYPE for HYPE via DEX swap
     * @dev Burns zHYPE, swaps kHYPE → HYPE via DEX, applies 5% fee
     * @param zhypeAmount Amount of zHYPE to redeem
     * @param encodedSwapData Encoded swap data from KyberSwap API
     * @param minHypeOut Minimum HYPE to receive (slippage protection)
     * @return hypeReceived Net HYPE received by user (after fee)
     */
    function swapRedeemLevercoin(
        uint256 zhypeAmount,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) external nonReentrant whenNotPaused returns (uint256 hypeReceived) {
        return _executeSwapRedeem(zhypeAmount, false, encodedSwapData, minHypeOut);
    }

    /**
     * @notice Internal function to execute SwapRedeem for both zUSD and zHYPE
     * @dev Consolidates common logic to save bytecode
     * @param tokenAmount Amount of zUSD or zHYPE to redeem
     * @param isZusd True for zUSD redemption, false for zHYPE
     * @param encodedSwapData Encoded swap data from KyberSwap API
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
            if (tokenAmount < minimumAmounts.redeemZusdMin) revert BelowMinimumAmount();
        } else {
            if (tokenAmount < minimumAmounts.redeemZhypeMin) revert BelowMinimumAmount();
        }

        // Check DEX integration is set
        if (address(dexIntegration) == address(0)) revert DexIntegrationNotSet();

        // Check user has enough tokens
        uint256 userBalance = isZusd ? zusd.balanceOf(msg.sender) : zhype.balanceOf(msg.sender);
        if (userBalance < tokenAmount) revert InsufficientBalance(userBalance, tokenAmount);

        // Get token NAV from Kinetiq (for NAV calculation)
        uint256 tokenNav = isZusd ? getZusdNavInHYPE() : getZhypeNavInHYPE();

        // Calculate kHYPE needed: (tokenAmount * tokenNav) / exchangeRate
        uint256 hypeEquivalent = (tokenAmount * tokenNav) / PRECISION;
        uint256 exchangeRate = kinetiq.getExchangeRate();
        uint256 khypeNeeded = (hypeEquivalent * PRECISION) / exchangeRate;

        // Check we have enough kHYPE
        if (khypeNeeded > totalKHYPEBalance) revert InsufficientReserves(khypeNeeded, totalKHYPEBalance);

        // Check rate divergence (Kinetiq vs DEX)
        _checkRateDivergence(khypeNeeded, minHypeOut, exchangeRate);

        // Burn tokens from user
        if (isZusd) {
            zusd.burn(msg.sender, tokenAmount);
        } else {
            zhype.burn(msg.sender, tokenAmount);
        }

        address khypeToken = kinetiq.getKHypeAddress();

        _withdrawKHYPEFromVault(khypeNeeded);

        IERC20(khypeToken).safeTransfer(address(dexIntegration), khypeNeeded);

        uint256 hypeSwapped = dexIntegration.executeSwap(
            encodedSwapData,
            khypeToken,
            NATIVE_HYPE,
            khypeNeeded,
            minHypeOut,
            address(this)
        );

        if (hypeSwapped < minHypeOut) revert InsufficientOutput(hypeSwapped, minHypeOut);

        uint256 fee = (hypeSwapped * swapRedeemFeeBps) / BASIS_POINTS;
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (!oracle.isValidPrice(hypePrice)) revert OraclePriceInvalid();

        accumulatedFees += (fee * hypePrice.price) / PRECISION;
        uint256 netHype = hypeSwapped - fee;

        totalKHYPEBalance -= khypeNeeded;

        // Reduce totalHYPECollateral to reflect withdrawn collateral
        // Use saturating subtraction to prevent accounting drift
        totalHYPECollateral = totalHYPECollateral >= hypeEquivalent ?
            totalHYPECollateral - hypeEquivalent : 0;

        // Decrease total deposits to allow new deposits after redemptions
        totalHypeDeposited = totalHypeDeposited >= hypeEquivalent ?
            totalHypeDeposited - hypeEquivalent : 0;

        // Transfer net HYPE to user (native transfer)
        // Note: We keep the fee in HYPE in the contract as protocol revenue
        (bool success, ) = payable(msg.sender).call{value: netHype}("");
        if (!success) revert HYPETransferFailed();

        userPositions[msg.sender].lastUpdateTime = block.timestamp;

        emit SwapRedeemExecuted(
            msg.sender,
            isZusd ? 0 : 1,
            tokenAmount,
            khypeNeeded,
            netHype,
            fee,
            (hypeEquivalent * hypePrice.price) / PRECISION
        );

        // Update system state
        _updateSystemState();

        return netHype;
    }

    /**
     * @notice Get quote for SwapRedeem operation
     * @dev Estimates HYPE output for a given token amount without executing the swap
     * @param tokenAmount Amount of zUSD or zHYPE to redeem
     * @param isZusd True for zUSD, false for zHYPE
     * @param expectedHypeFromDex Expected HYPE from DEX (from frontend API call)
     * @return khypeNeeded Amount of kHYPE needed for swap
     * @return grossHype Gross HYPE before fee
     * @return fee SwapRedeem fee amount
     * @return netHype Net HYPE user will receive
     * @return usdValue USD value of redemption
     */
    function getSwapRedeemQuote(
        uint256 tokenAmount,
        bool isZusd,
        uint256 expectedHypeFromDex
    ) external view returns (
        uint256 khypeNeeded,
        uint256 grossHype,
        uint256 fee,
        uint256 netHype,
        uint256 usdValue
    ) {
        // Get token NAV
        uint256 tokenNav = isZusd ? getZusdNavInHYPE() : getZhypeNavInHYPE();

        // Calculate kHYPE needed
        uint256 hypeEquivalent = (tokenAmount * tokenNav) / PRECISION;
        uint256 exchangeRate = kinetiq.getExchangeRate();
        khypeNeeded = (hypeEquivalent * PRECISION) / exchangeRate;

        // Gross HYPE from DEX (provided by caller from API)
        grossHype = expectedHypeFromDex;

        // Calculate fee
        fee = (grossHype * swapRedeemFeeBps) / BASIS_POINTS;
        netHype = grossHype - fee;

        // Calculate USD value
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price > 0) {
            usdValue = (hypeEquivalent * hypePrice.price) / PRECISION;
        }

        return (khypeNeeded, grossHype, fee, netHype, usdValue);
    }

    /**
     * @notice Check if a redemption is ready to claim
     * @param redemptionId ID of the redemption to check
     * @return ready True if ready to claim (queried from Kinetiq)
     * @return timeRemaining Always 0 (Kinetiq doesn't provide time remaining)
     */
    function isRedemptionReady(uint256 redemptionId) external view returns (bool ready, uint256 timeRemaining) {
        return withdrawals.isWithdrawalReady(redemptionId, kinetiq);
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
    function getRedemptionDetails(uint256 redemptionId) external view returns (
        address requester,
        uint256 tokenAmount,
        uint256 expectedHype,
        bool isZusd,
        uint8 state
    ) {
        HypeZionWithdrawalManagerLibrary.WithdrawalRequest memory request = withdrawals.requests[redemptionId];
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
     * @notice Collect accumulated fees (owner only)
     */
    function collectFees() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 fees = accumulatedFees;
        accumulatedFees = 0;

        // Mint fee amount as zUSD to owner
        zusd.mint(msg.sender, fees);

        emit FeesCollected(msg.sender, fees);
    }

    /**
     * @notice Set the protocol version (owner only)
     * @param version New version string
     */
    function setProtocolVersion(string calldata version) external onlyRole(DEFAULT_ADMIN_ROLE) {
        protocolVersion = version;
    }


    /**
     * @notice Fund reserves with HYPE to improve system health
     * @dev Owner-only function to directly inject HYPE into reserves
     *      This helps bootstrap the system or recover from Critical state
     *      The HYPE is staked through Kinetiq to earn yield
     *      Note: Does not mint tokens - purely adds to reserves
     * @param amountHYPE Amount of HYPE to add to reserves
     */
    function fundReserves(uint256 amountHYPE) external payable onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (msg.value != amountHYPE) revert IncorrectHYPEAmount();

        // Stake HYPE through Kinetiq to earn yield
        uint256 kHYPEReceived = kinetiq.stakeHYPE{value: amountHYPE}(amountHYPE);

        // Update protocol balances
        totalHYPECollateral += amountHYPE;
        totalKHYPEBalance += kHYPEReceived;

        // Immediately deposit kHYPE to vault for yield earning
        _depositKHYPEToVault(kHYPEReceived);

        // Get updated metrics
        uint256 newTotalReserves = getTotalReserveInHYPE();
        uint256 newCR = getSystemCR();

        // Update system state if CR improved
        _updateSystemState();

        emit ReservesFunded(msg.sender, amountHYPE, newTotalReserves, newCR);
    }

    /**
     * @notice Settle pending yield if available before redemption
     * @dev Called internally before redemptions to ensure NAV is current
     * @return yieldSettled Amount of yield that was settled (in HYPE)
     */
    function _settleYieldIfNeeded() internal returns (uint256 yieldSettled) {
        // Get yield manager address
        address yieldManagerAddr = kinetiq.getYieldManager();
        if (yieldManagerAddr == address(0)) {
            return 0; // No yield manager configured
        }

        // Cast to KinetiqYieldManager interface (using same ABI as we'll check)
        // We'll use low-level calls to avoid interface import issues

        // Check if there's harvestable yield
        (bool success1, bytes memory data1) = yieldManagerAddr.staticcall(
            abi.encodeWithSignature("calculateYield()")
        );
        if (!success1) return 0;
        uint256 pendingYield = abi.decode(data1, (uint256));

        // Only settle if yield meets minimum threshold (avoid gas waste on tiny amounts)
        if (pendingYield < MIN_YIELD_TO_SETTLE) {
            return 0;
        }

        // Check if harvest cooldown allows settling now
        (bool success2, bytes memory data2) = yieldManagerAddr.staticcall(
            abi.encodeWithSignature("canHarvest()")
        );
        if (!success2) return 0;
        (bool canHarvest, ) = abi.decode(data2, (bool, uint256));
        if (!canHarvest) {
            return 0; // Cooldown active, skip settling
        }

        // Queue yield withdrawal
        (bool success3, bytes memory data3) = yieldManagerAddr.call(
            abi.encodeWithSignature("queueYieldWithdrawal()")
        );
        if (!success3) {
            // Yield settlement failed (e.g., amount too small after queue)
            // Continue with redemption using current NAV
            return 0;
        }

        uint256 withdrawalId = abi.decode(data3, (uint256));

        // Yield queued successfully, but not yet claimable
        // Future redemptions will benefit from the updated NAV once claimed
        emit YieldSettlementQueued(withdrawalId, pendingYield);
        return pendingYield;
    }

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
    function setSwapRedeemPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        if (khypeAmount == 0) revert AmountMustBeGreaterThanZero();

        // Get kHYPE token address
        address khypeToken = kinetiq.getKHypeAddress();

        // Approve vault to spend kHYPE (if not already approved)
        uint256 currentAllowance = IERC20(khypeToken).allowance(address(this), address(hypeZionVault));
        if (currentAllowance < khypeAmount) {
            IERC20(khypeToken).approve(address(hypeZionVault), type(uint256).max);
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
    function _withdrawKHYPEFromVault(uint256 khypeAmount) internal returns (uint256 actualReceived) {
        if (address(hypeZionVault) == address(0)) revert VaultNotSet();
        if (khypeAmount == 0) revert AmountMustBeGreaterThanZero();

        // Get kHYPE balance before withdrawal
        address khypeToken = kinetiq.getKHypeAddress();
        uint256 balanceBefore = IERC20(khypeToken).balanceOf(address(this));

        // Calculate shares needed for the kHYPE amount
        // Use previewWithdraw to get exact shares needed
        uint256 sharesNeeded = hypeZionVault.previewWithdraw(khypeAmount);

        // Withdraw from vault (burn shares, receive kHYPE)
        hypeZionVault.redeem(sharesNeeded, address(this), address(this));

        // Verify actual received amount
        uint256 balanceAfter = IERC20(khypeToken).balanceOf(address(this));
        actualReceived = balanceAfter - balanceBefore;

        if (actualReceived < khypeAmount) revert InsufficientBalance(khypeAmount, actualReceived);

        return actualReceived;
    }

    /// @notice Withdraw kHYPE from vault for yield (YieldManager only)
    function withdrawKHYPEForYield(uint256 k) external {
        require(msg.sender == address(kinetiq.getYieldManager()));
        _withdrawKHYPEFromVault(k);
        IERC20(kinetiq.getKHypeAddress()).safeTransfer(address(kinetiq), k);
    }


    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to owner
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

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
    function setMaximumLimits(uint256 _maxTotalDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTotalDeposit = _maxTotalDeposit;
        emit MaximumLimitsUpdated(_maxTotalDeposit);
    }

    /**
     * @notice Set protocol fee configuration (basis points)
     * @param _feeHealthy Fee when CR >= 150% (e.g., 30 = 0.3%)
     * @param _feeCautious Fee when 130% <= CR < 150% (e.g., 20 = 0.2%)
     * @param _feeCritical Fee when CR < 130% (e.g., 10 = 0.1%)
     */
    function setProtocolFees(
        uint256 _feeHealthy,
        uint256 _feeCautious,
        uint256 _feeCritical
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeHealthy > 1000) revert FeeTooHigh(); // Max 10%
        if (_feeCautious > 1000) revert FeeTooHigh();
        if (_feeCritical > 1000) revert FeeTooHigh();

        feeHealthy = _feeHealthy;
        feeCautious = _feeCautious;
        feeCritical = _feeCritical;

        emit ProtocolFeeUpdated(_feeHealthy, _feeCautious, _feeCritical);
    }

    /**
     * @notice Set swap redeem configuration
     * @param _swapRedeemFeeBps Fee for swap redeem operations in basis points (e.g., 500 = 5%)
     * @param _maxRateDivergenceBps Maximum allowed rate divergence in basis points (e.g., 1000 = 10%)
     */
    function setSwapRedeemConfig(
        uint256 _swapRedeemFeeBps,
        uint256 _maxRateDivergenceBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_swapRedeemFeeBps > 2000) revert FeeTooHigh(); // Max 20%
        if (_maxRateDivergenceBps > 5000) revert RateDivergenceTooHigh(_maxRateDivergenceBps, 5000); // Max 50%

        swapRedeemFeeBps = _swapRedeemFeeBps;
        maxRateDivergenceBps = _maxRateDivergenceBps;

        emit SwapRedeemConfigUpdated(_swapRedeemFeeBps, _maxRateDivergenceBps);
    }
}