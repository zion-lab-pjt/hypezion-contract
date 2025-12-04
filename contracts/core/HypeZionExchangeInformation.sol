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

    IHypeZionExchange public exchange;

    struct ProtocolInformation {
        // Protocol version
        string version;                // Protocol version from package.json

        // NAV information (18 decimals)
        uint256 zusdNavInHYPE;        // zUSD NAV in HYPE terms
        uint256 zhypeNavInHYPE;       // zHYPE NAV in HYPE terms

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
        uint256 accumulatedProtocolFees; // Fees accumulated by protocol

        // Kinetiq integration (18 decimals)
        uint256 kinetiqExchangeRate;  // Current kHYPE/HYPE exchange rate

        // Leverage and APY metrics (per Hylo whitepaper)
        uint256 zhypeLeverage;        // Effective leverage = TotalReserves/zHYPE_MarketCap (1e18 = 1x)
        uint256 stabilityPoolAPY;     // APY = BaseYield × RevenueShare × StakingConcentration (basis points)

        // Metadata
        uint256 lastUpdated;          // Block timestamp of this snapshot
    }

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap;

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

        // zHYPE NAV in USD
        uint256 zhypeNavInHYPE = exchange.getZhypeNavInHYPE();
        IOracle oracle = IOracle(exchange.oracle());
        IOracle.PriceData memory hypePriceData = oracle.getPrice("HYPE");
        hypePrice = hypePriceData.price; // HYPE price in USD
        zhypeNav = (zhypeNavInHYPE * hypePrice) / PRECISION;

        // szUSD NAV (share price)
        szusdNav = exchange.getSzUSDNavInUSD();
    }

    /**
     * @notice Get comprehensive protocol information
     * @return info ProtocolInformation struct with all protocol metrics
     */
    function protocolInformation() external view returns (ProtocolInformation memory info) {
        // Calculate all NAVs and metrics
        uint256 zusdNav = exchange.getZusdNavInHYPE();

        // Try to get zHYPE NAV, return 0 if in critical state
        uint256 zhypeNav = 0;
        try exchange.getZhypeNavInHYPE() returns (uint256 nav) {
            zhypeNav = nav;
        } catch {
            // In critical state or insufficient reserves
            zhypeNav = 0;
        }

        uint256 totalReserve = exchange.getTotalReserveInHYPE();
        uint256 zusdLiabilities = exchange.getZusdLiabilitiesInHYPE();
        uint256 systemCR = exchange.getSystemCR();
        uint256 currentFee = exchange.getCurrentFee();

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

        // Calculate stability pool APY using dedicated function
        uint256 stabilityPoolAPY = _calculateStabilityPoolAPY(stabilityPool, kinetiqExchangeRate, zusdSupply);

        return ProtocolInformation({
            // Protocol version
            version: exchange.protocolVersion(),

            // NAV information
            zusdNavInHYPE: zusdNav,
            zhypeNavInHYPE: zhypeNav,

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

    /**
     * @notice Calculate stability pool APY based on Kinetiq yield and concentration effect
     * @param stabilityPool StabilityPool contract instance
     * @param kinetiqExchangeRate Current kHYPE/HYPE exchange rate from Kinetiq
     * @param zusdSupply Total zUSD supply
     * @return apy APY in basis points (10000 = 100%)
     * @dev Implements whitepaper formula with dynamic staking concentration:
     *      APY = Base_Yield × Concentration_Multiplier
     *      Where Concentration_Multiplier = Total_Supply / Staked_Amount
     *      Returns 0 if no funds are staked (no APY without participation)
     */
    function _calculateStabilityPoolAPY(
        IStabilityPool stabilityPool,
        uint256 kinetiqExchangeRate,
        uint256 zusdSupply
    ) internal view returns (uint256 apy) {
        // Early return if no yield or no supply
        if (kinetiqExchangeRate <= PRECISION || zusdSupply == 0) {
            return 0;
        }

        // Get actual staked amount from StabilityPool (szUSD)
        uint256 stakedAmount = stabilityPool.totalAssets();

        // No APY if nothing is staked - this is the correct economic behavior
        // First stakers will see APY immediately after depositing
        if (stakedAmount == 0) {
            return 0;
        }

        // Base yield from Kinetiq (LST staking)
        uint256 baseYieldBasisPoints = ((kinetiqExchangeRate - PRECISION) * BASIS_POINTS) / PRECISION;

        // Calculate concentration multiplier
        // stakedPercent = (stakedAmount / zusdSupply) * 10000
        uint256 stakedPercent = (stakedAmount * BASIS_POINTS) / zusdSupply;

        // Apply concentration effect: APY = BaseYield × (10000 / stakedPercent)
        // This simplifies to: APY = BaseYield × zusdSupply / stakedAmount
        apy = (baseYieldBasisPoints * BASIS_POINTS) / stakedPercent;

        // Cap APY at 10000 basis points (100%) to prevent unrealistic values
        // This prevents gaming with dust amounts
        if (apy > 10000) {
            apy = 10000;
        }

        return apy;
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to admin
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
