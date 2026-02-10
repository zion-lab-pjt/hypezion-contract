// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";

/**
 * @title HypeZionExchangeInformation
 * @notice Provides view functions for protocol information by reading state from HypeZionExchange
 * @dev Created to reduce HypeZionExchange contract size by extracting heavy view functions
 *      Implements UUPS upgradeable pattern for future enhancements
 */
contract HypeZionExchangeInformation is AccessControlUpgradeable, UUPSUpgradeable {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    IHypeZionExchange public exchange;

    // Rolling window snapshot system for APY calculation
    // Store weekly exchange rate snapshots to calculate 14-day rolling APY
    mapping(uint256 => uint256) public rateSnapshots; // week number => exchange rate
    uint256 public latestSnapshotWeek;
    uint256 public snapshotCount; // Number of snapshots taken (for warm-up period detection)
    uint256 public initialSnapshotWeek; // Week number when first snapshot was created (for upgrade safety)
    uint256 public constant SNAPSHOT_INTERVAL = 7 days; // Save rate every week
    uint256 public constant APY_WINDOW = 14 days; // Calculate APY from 2-week window

    // Warm-up APY estimate (2% = 200 basis points) - conservative estimate for Kinetiq yield
    uint256 public constant WARMUP_APY_ESTIMATE = 200;

    struct ProtocolInformation {
        // Protocol version
        string version;                // Protocol version from package.json

        // NAV information (18 decimals)
        uint256 zusdNavInHYPE;        // zUSD NAV in HYPE terms
        uint256 zhypeNavInHYPE;       // zHYPE NAV in HYPE terms
        uint256 szusdNavInHYPE;       // szUSD NAV in HYPE terms (share price converted)

        // Reserve and liability information (18 decimals)
        uint256 totalReserveInHYPE;   // Total protocol reserves in HYPE
        uint256 zusdLiabilitiesInHYPE; // Total zUSD debt in HYPE terms

        // System health metrics
        uint256 systemCollateralRatio; // System CR (basis points, 10000 = 100%)
        uint8 systemState;            // 0=Normal, 1=Cautious, 2=Critical
        uint256 currentFeeBasisPoints; // Current protocol fee in basis points

        // Token supply information (18 decimals)
        uint256 zusdTotalSupply;      // Total zUSD in circulation
        uint256 zhypeTotalSupply;     // Total zHYPE in circulation
        uint256 szusdTotalSupply;     // Total szUSD (StakedZUSD) in circulation

        // Protocol balances (18 decimals)
        uint256 totalHYPECollateral;  // Total HYPE staked in protocol
        uint256 totalKHYPEBalance;    // Total kHYPE held by protocol
        uint256 accumulatedProtocolFees; // Fees accumulated by protocol (in kHYPE units, convert via exchangeRate for HYPE value)

        // Kinetiq integration (18 decimals)
        uint256 kinetiqExchangeRate;  // Current kHYPE/HYPE exchange rate

        // Leverage and APY metrics (per Hylo whitepaper)
        uint256 zhypeLeverage;        // Effective leverage = TotalReserves/zHYPE_MarketCap (1e18 = 1x)
        uint256 stabilityPoolAPY;     // APY = BaseYield × RevenueShare × StakingConcentration (basis points)

        // Metadata
        uint256 lastUpdated;          // Block timestamp of this snapshot
    }

    // Storage gap for future upgrades (UUPS pattern)
    // Reduced from 47 to 46 after adding initialSnapshotWeek
    uint256[46] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the information contract
     * @param _exchange Address of HypeZionExchange contract
     */
    function initialize(address _exchange) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        require(_exchange != address(0), "Invalid exchange address");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        exchange = IHypeZionExchange(_exchange);

        // Initialize rolling window snapshot system
        IKinetiqIntegration kinetiq = IKinetiqIntegration(exchange.kinetiq());
        uint256 currentRate = kinetiq.getExchangeRate();

        // Create initial snapshot
        uint256 currentWeek = block.timestamp / SNAPSHOT_INTERVAL;
        rateSnapshots[currentWeek] = currentRate;
        initialSnapshotWeek = currentWeek;
        latestSnapshotWeek = currentWeek;
        snapshotCount = 1; // First snapshot created during initialization
    }

    /**
     * @notice Reinitialize for upgrades - sets initialSnapshotWeek if not already set
     * @dev Call this after upgrading from a version without initialSnapshotWeek
     *      Safe to call multiple times - only sets if currently 0
     */
    function reinitializeSnapshotTracking() external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Only set if not already initialized (for upgrades from older versions)
        if (initialSnapshotWeek == 0 && snapshotCount > 0) {
            // For existing deployments, use latestSnapshotWeek - snapshotCount + 1 as approximation
            // This assumes snapshots were taken somewhat regularly
            // If not, the warm-up period will just be slightly longer (safe behavior)
            initialSnapshotWeek = latestSnapshotWeek >= snapshotCount ?
                latestSnapshotWeek - snapshotCount + 1 :
                0;
        }
    }

    /**
     * @notice Get protocol NAV values in USD
     * @return zusdNav zUSD NAV in USD (always 1e18 = $1)
     * @return zhypeNav zHYPE NAV in USD
     * @return szusdNav szUSD NAV in USD (share price)
     * @return hypePrice HYPE price in USD
     */
    function getProtocolNavInUSD() external view returns (
        uint256 zusdNav,
        uint256 zhypeNav,
        uint256 szusdNav,
        uint256 hypePrice
    ) {
        // zUSD NAV is always $1
        zusdNav = PRECISION; // 1e18 = $1.00

        // Get HYPE price first
        IOracle oracle = IOracle(exchange.oracle());
        IOracle.PriceData memory hypePriceData = oracle.getPrice("HYPE");
        hypePrice = hypePriceData.price; // HYPE price in USD

        // zHYPE NAV in USD - may fail in emergency state (CR < 100%)
        try exchange.getZhypeNavInHYPE() returns (uint256 zhypeNavInHYPE) {
            zhypeNav = (zhypeNavInHYPE * hypePrice) / PRECISION;
        } catch {
            // In emergency state, zHYPE NAV is 0
            zhypeNav = 0;
        }

        // szUSD NAV (share price) - may fail in emergency state
        try exchange.getSzUSDNavInUSD() returns (uint256 nav) {
            szusdNav = nav;
        } catch {
            szusdNav = 0;
        }
    }

    /**
     * @notice Get comprehensive protocol information
     * @return info ProtocolInformation struct with all protocol metrics
     */
    function protocolInformation() external view returns (ProtocolInformation memory info) {
        // Calculate all NAVs and metrics with try-catch for emergency state resilience
        uint256 zusdNav = 0;
        try exchange.getZusdNavInHYPE() returns (uint256 nav) {
            zusdNav = nav;
        } catch {
            zusdNav = PRECISION; // Default to 1:1 in emergency
        }

        // Try to get zHYPE NAV, return 0 if in critical state
        uint256 zhypeNav = 0;
        try exchange.getZhypeNavInHYPE() returns (uint256 nav) {
            zhypeNav = nav;
        } catch {
            // In critical state or insufficient reserves
            zhypeNav = 0;
        }

        // Calculate szUSD NAV in HYPE terms
        // szUSD NAV (share price) is in USD, convert to HYPE using oracle price
        uint256 szusdNav = 0;
        try exchange.getSzUSDNavInUSD() returns (uint256 navInUsd) {
            // Get HYPE price from oracle
            IOracle oracle = IOracle(exchange.oracle());
            try oracle.getPrice("HYPE") returns (IOracle.PriceData memory hypePriceData) {
                if (hypePriceData.price > 0) {
                    // Convert USD to HYPE: navInUsd / hypePrice
                    // szusdNavInHYPE = navInUsd * PRECISION / hypePrice
                    szusdNav = (navInUsd * PRECISION) / hypePriceData.price;
                }
            } catch {
                szusdNav = 0;
            }
        } catch {
            szusdNav = 0;
        }

        // Try to get reserves - may fail if Kinetiq has issues
        uint256 totalReserve = 0;
        try exchange.getTotalReserveInHYPE() returns (uint256 reserve) {
            totalReserve = reserve;
        } catch {
            // Fallback: use raw collateral values
            totalReserve = exchange.totalHYPECollateral();
        }

        // Try to get liabilities
        uint256 zusdLiabilities = 0;
        try exchange.getZusdLiabilitiesInHYPE() returns (uint256 liabilities) {
            zusdLiabilities = liabilities;
        } catch {
            zusdLiabilities = 0;
        }

        // Try to get system CR
        uint256 systemCR = 0;
        try exchange.getSystemCR() returns (uint256 cr) {
            systemCR = cr;
        } catch {
            // In emergency, calculate from available data
            if (zusdLiabilities > 0) {
                systemCR = (totalReserve * BASIS_POINTS) / zusdLiabilities;
            }
        }

        uint256 currentFee = exchange.getProtocolFee(true, true);  // hzUSD mint fee as default

        // Get token supplies
        HzUSD zusd = HzUSD(exchange.zusd());
        BullHYPE zhype = BullHYPE(exchange.zhype());
        IStabilityPool stabilityPool = IStabilityPool(exchange.stabilityPool());

        uint256 zusdSupply = zusd.totalSupply();
        uint256 zhypeSupply = zhype.totalSupply();
        uint256 szusdSupply = stabilityPool.totalSupply();

        // Get Kinetiq information
        IKinetiqIntegration kinetiq = IKinetiqIntegration(exchange.kinetiq());
        uint256 kinetiqExchangeRate = 0;
        try kinetiq.getExchangeRate() returns (uint256 rate) {
            kinetiqExchangeRate = rate;
        } catch {
            kinetiqExchangeRate = PRECISION; // 1:1 fallback
        }

        // Calculate zHYPE leverage using dedicated function
        uint256 zhypeLeverage = _calculateZhypeLeverage(totalReserve, zhypeSupply, zhypeNav);

        // Calculate stability pool APY - may fail in emergency state
        uint256 stabilityPoolAPY = 0;
        try this.calculateStabilityPoolAPYSafe(stabilityPool, kinetiqExchangeRate, zusdSupply) returns (uint256 apy) {
            stabilityPoolAPY = apy;
        } catch {
            stabilityPoolAPY = 0;
        }

        return ProtocolInformation({
            // Protocol version
            version: exchange.protocolVersion(),

            // NAV information
            zusdNavInHYPE: zusdNav,
            zhypeNavInHYPE: zhypeNav,
            szusdNavInHYPE: szusdNav,

            // Reserve and liability information
            totalReserveInHYPE: totalReserve,
            zusdLiabilitiesInHYPE: zusdLiabilities,

            // System health metrics
            systemCollateralRatio: systemCR,
            systemState: uint8(exchange.systemState()),
            currentFeeBasisPoints: currentFee,

            // Token supply information
            zusdTotalSupply: zusdSupply,
            zhypeTotalSupply: zhypeSupply,
            szusdTotalSupply: szusdSupply,

            // Protocol balances
            totalHYPECollateral: exchange.totalHYPECollateral(),
            totalKHYPEBalance: exchange.totalKHYPEBalance(),
            accumulatedProtocolFees: exchange.accumulatedFees(),

            // Kinetiq integration
            kinetiqExchangeRate: kinetiqExchangeRate,

            // Leverage and APY metrics
            zhypeLeverage: zhypeLeverage,
            stabilityPoolAPY: stabilityPoolAPY,

            // Timestamp
            lastUpdated: block.timestamp
        });
    }

    /**
     * @notice Calculate zHYPE leverage from reserve and supply data
     * @param totalReserve Total reserves in HYPE
     * @param zhypeSupply Total zHYPE supply
     * @param zhypeNav zHYPE NAV in HYPE
     * @return leverage Leverage multiplier (1e18 = 1x)
     */
    function _calculateZhypeLeverage(
        uint256 totalReserve,
        uint256 zhypeSupply,
        uint256 zhypeNav
    ) internal pure returns (uint256 leverage) {
        // Default 1x leverage
        leverage = PRECISION;

        if (zhypeSupply > 0 && zhypeNav > 0) {
            // Calculate zHYPE market cap in HYPE terms
            uint256 zhypeMarketCap = (zhypeSupply * zhypeNav) / PRECISION;
            if (zhypeMarketCap > 0) {
                // Leverage = Total Reserves / zHYPE Market Cap
                leverage = (totalReserve * PRECISION) / zhypeMarketCap;
            }
        }

        return leverage;
    }

    // Event for rate snapshot updates
    event RateSnapshotUpdated(uint256 indexed week, uint256 rate, uint256 timestamp);

    /**
     * @notice Update exchange rate snapshot (called by keeper/bot)
     * @dev This function should be called daily by a cron job/keeper
     *      It will only update once per week (even if called daily)
     *      Anyone can call this, but it only updates if we don't have the current week's snapshot
     */
    function updateRateSnapshot() external {
        uint256 currentWeek = block.timestamp / SNAPSHOT_INTERVAL;

        // Only update if we don't have this week's snapshot yet
        if (currentWeek > latestSnapshotWeek) {
            IKinetiqIntegration kinetiq = IKinetiqIntegration(exchange.kinetiq());
            uint256 currentRate = kinetiq.getExchangeRate();

            // Save new snapshot
            rateSnapshots[currentWeek] = currentRate;
            latestSnapshotWeek = currentWeek;
            snapshotCount++; // Increment snapshot counter

            // Clean up old snapshots to save gas (keep last 10 weeks)
            if (currentWeek > 10) {
                delete rateSnapshots[currentWeek - 10];
            }

            emit RateSnapshotUpdated(currentWeek, currentRate, block.timestamp);
        }
        // If currentWeek == latestSnapshotWeek, silently do nothing (already have this week's snapshot)
    }

    /**
     * @notice Calculate stability pool APY (external wrapper for try-catch compatibility)
     * @dev Public function that wraps _calculateStabilityPoolAPY for try-catch usage
     */
    function calculateStabilityPoolAPYSafe(
        IStabilityPool stabilityPool,
        uint256 kinetiqExchangeRate,
        uint256 zusdSupply
    ) external view returns (uint256) {
        return _calculateStabilityPoolAPY(stabilityPool, kinetiqExchangeRate, zusdSupply);
    }

    /**
     * @notice Calculate stability pool APY based on 14-day rolling window
     * @param stabilityPool StabilityPool contract instance
     * @param kinetiqExchangeRate Current kHYPE/HYPE exchange rate from Kinetiq
     * @param zusdSupply Total zUSD supply
     * @return apy APY in basis points (10000 = 100%)
     * @dev Implements 14-day rolling window APY calculation to match Kinetiq's methodology:
     *      APY = Rolling_Window_Yield × Concentration_Multiplier
     *
     *      IMPORTANT: Concentration is based on TOTAL protocol HYPE, not just hzUSD backing.
     *      All protocol HYPE (backing both hzUSD and BullHYPE) generates yield for szUSD holders.
     *
     *      Concentration_Multiplier = Total_Protocol_HYPE / Staked_Amount_In_HYPE
     *      Where:
     *        - Total_Protocol_HYPE = getTotalReserveInHYPE() (hzUSD + BullHYPE backing)
     *        - Staked_Amount_In_HYPE = szUSD_staked × (zusdLiabilities / zusdSupply)
     *
     *      Rolling_Window_Yield = (Current_Rate - Rate_2_Weeks_Ago) / Rate_2_Weeks_Ago
     *      Annualized_APY = Rolling_Window_Yield × (365_days / 14_days)
     *
     *      Warm-up behavior:
     *      - Uses conservative 2% estimate when not enough snapshot history
     *      - Falls back to warm-up estimate if snapshots are missing (non-consecutive weeks)
     *
     *      Returns 0 only if:
     *      - No funds are staked
     *      - Exchange rate decreased (negative yield)
     */
    function _calculateStabilityPoolAPY(
        IStabilityPool stabilityPool,
        uint256 kinetiqExchangeRate,
        uint256 zusdSupply
    ) internal view returns (uint256 apy) {
        // Early return if no supply
        if (zusdSupply == 0) {
            return 0;
        }

        // Get actual staked amount from StabilityPool (szUSD)
        uint256 stakedAmount = stabilityPool.totalAssets();

        // No APY if nothing is staked
        if (stakedAmount == 0) {
            return 0;
        }

        // Step 1: Calculate base Kinetiq APY (before concentration multiplier)
        uint256 baseKinetiqAPY = _calculateBaseKinetiqAPY(kinetiqExchangeRate);

        // If base APY is 0 (rate decreased), return 0
        if (baseKinetiqAPY == 0) {
            return 0;
        }

        // Step 2: Apply concentration multiplier based on TOTAL protocol HYPE
        apy = _applyConcentrationMultiplier(baseKinetiqAPY, stakedAmount, zusdSupply);

        // Step 3: Cap APY at 10000 basis points (100%) to prevent unrealistic values
        if (apy > 10000) {
            apy = 10000;
        }

        return apy;
    }

    /**
     * @notice Calculate base Kinetiq APY from rolling window or warm-up estimate
     * @param kinetiqExchangeRate Current kHYPE/HYPE exchange rate
     * @return baseAPY Base APY in basis points (before concentration multiplier)
     * @dev Returns warm-up estimate (2%) if:
     *      - Not enough time elapsed since deployment (< 2 weeks)
     *      - Snapshot data is missing (keeper missed weeks)
     *      Returns 0 if exchange rate decreased (no yield to distribute)
     */
    function _calculateBaseKinetiqAPY(uint256 kinetiqExchangeRate) internal view returns (uint256 baseAPY) {
        // Check if we have enough elapsed time for rolling window calculation
        // Use initialSnapshotWeek for accurate tracking (handles upgrades gracefully)
        bool hasEnoughHistory = _hasValidRollingWindow();

        if (!hasEnoughHistory) {
            // Warm-up period: use conservative estimate
            return WARMUP_APY_ESTIMATE;
        }

        // Try to get rate from 2 weeks ago
        uint256 twoWeeksAgoWeek = latestSnapshotWeek >= 2 ? latestSnapshotWeek - 2 : 0;
        uint256 twoWeeksAgoRate = rateSnapshots[twoWeeksAgoWeek];

        // If snapshot is missing (keeper missed weeks), fall back to warm-up estimate
        // This is safer than returning 0 which would confuse users
        if (twoWeeksAgoRate == 0) {
            return WARMUP_APY_ESTIMATE;
        }

        // If rate decreased or stayed same, no yield to distribute
        if (kinetiqExchangeRate <= twoWeeksAgoRate) {
            return 0;
        }

        // Calculate yield growth over the 14-day window
        // Growth = (Current_Rate - Rate_2_Weeks_Ago) / Rate_2_Weeks_Ago
        uint256 yieldGrowthBasisPoints = ((kinetiqExchangeRate - twoWeeksAgoRate) * BASIS_POINTS) / twoWeeksAgoRate;

        // ANNUALIZE the 14-day growth to yearly rate
        // Formula: Annualized_Yield = 14_Day_Growth × (365_days / 14_days)
        baseAPY = (yieldGrowthBasisPoints * SECONDS_PER_YEAR) / APY_WINDOW;

        return baseAPY;
    }

    /**
     * @notice Check if we have a valid 2-week rolling window
     * @return hasWindow True if enough time has passed for rolling window calculation
     * @dev Handles both new deployments and upgrades from older versions
     */
    function _hasValidRollingWindow() internal view returns (bool hasWindow) {
        // For upgrades from older versions where initialSnapshotWeek wasn't set
        // Fall back to snapshotCount check (less accurate but safe)
        if (initialSnapshotWeek == 0) {
            return snapshotCount >= 3; // Be conservative for old deployments
        }

        // Check if at least 2 weeks have passed since initial snapshot
        return latestSnapshotWeek >= initialSnapshotWeek + 2;
    }

    /**
     * @notice Apply concentration multiplier to base APY
     * @param baseAPY Base APY in basis points
     * @param stakedAmount Amount staked in stability pool (hzUSD units)
     * @param zusdSupply Total hzUSD supply
     * @return apy Final APY with concentration multiplier applied
     * @dev Uses improved precision by combining multiplications before division
     *      Concentration = Total_Protocol_HYPE / Staked_HYPE
     */
    function _applyConcentrationMultiplier(
        uint256 baseAPY,
        uint256 stakedAmount,
        uint256 zusdSupply
    ) internal view returns (uint256 apy) {
        uint256 totalReserveInHYPE = exchange.getTotalReserveInHYPE();
        uint256 zusdLiabilitiesInHYPE = exchange.getZusdLiabilitiesInHYPE();

        // Early return if no reserves (shouldn't happen if zusdSupply > 0)
        if (totalReserveInHYPE == 0 || zusdLiabilitiesInHYPE == 0) {
            return 0;
        }

        // Improved precision: combine multiplications before divisions
        // Formula: APY = baseAPY × (totalReserve / stakedAmountInHYPE)
        //        = baseAPY × (totalReserve × zusdSupply) / (stakedAmount × zusdLiabilities)
        //
        // stakedPercent = (stakedAmount × zusdLiabilities × BASIS_POINTS) / (zusdSupply × totalReserve)
        // APY = baseAPY × BASIS_POINTS / stakedPercent
        //     = baseAPY × zusdSupply × totalReserve / (stakedAmount × zusdLiabilities)

        // Calculate numerator and denominator separately to avoid overflow
        // numerator = baseAPY × totalReserve × zusdSupply
        // denominator = stakedAmount × zusdLiabilities
        //
        // But this could overflow for large values. Let's use the two-step approach
        // with improved ordering:

        // Step 1: Calculate staked percent with better precision
        // stakedPercent = (stakedAmount × zusdLiabilities × BASIS_POINTS) / (zusdSupply × totalReserve)
        uint256 numerator = stakedAmount * zusdLiabilitiesInHYPE;
        uint256 denominator = zusdSupply * totalReserveInHYPE;

        // Avoid division by zero
        if (denominator == 0) {
            return 0;
        }

        // Calculate staked percent (in basis points)
        uint256 stakedPercent = (numerator * BASIS_POINTS) / denominator;

        // Prevent division by zero - minimum 1 basis point (0.01%)
        if (stakedPercent == 0) {
            stakedPercent = 1;
        }

        // Apply concentration effect: APY = baseAPY × (10000 / stakedPercent)
        apy = (baseAPY * BASIS_POINTS) / stakedPercent;

        return apy;
    }

    /**
     * @notice Get quote for SwapRedeem operation
     * @dev Estimates HYPE output for a given token amount without executing the swap
     *      Moved from HypeZionExchange to reduce contract size
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
        // Get token NAV from exchange
        uint256 tokenNav;
        if (isZusd) {
            tokenNav = exchange.getZusdNavInHYPE();
        } else {
            try exchange.getZhypeNavInHYPE() returns (uint256 nav) {
                tokenNav = nav;
            } catch {
                tokenNav = 0; // In emergency state
            }
        }

        // Calculate kHYPE needed
        uint256 hypeEquivalent = (tokenAmount * tokenNav) / PRECISION;
        IKinetiqIntegration kinetiq = IKinetiqIntegration(exchange.kinetiq());
        uint256 exchangeRate = kinetiq.getExchangeRate();
        khypeNeeded = (hypeEquivalent * PRECISION) / exchangeRate;

        // Gross HYPE from DEX (provided by caller from API)
        grossHype = expectedHypeFromDex;

        // Calculate fee using getProtocolFee (unified with regular redeem)
        uint256 feeBps = exchange.getProtocolFee(isZusd, false);  // false = redeem
        fee = (grossHype * feeBps) / BASIS_POINTS;
        netHype = grossHype - fee;

        // Calculate USD value
        IOracle oracle = IOracle(exchange.oracle());
        IOracle.PriceData memory hypePrice = oracle.getPrice("HYPE");
        if (hypePrice.price > 0) {
            usdValue = (hypeEquivalent * hypePrice.price) / PRECISION;
        }

        return (khypeNeeded, grossHype, fee, netHype, usdValue);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to admin
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
