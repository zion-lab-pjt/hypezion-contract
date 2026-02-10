// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./IOracle.sol";
import "./IStabilityPool.sol";
import "./IKinetiqIntegration.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";

interface IHypeZionExchange {
    // Enums
    enum SystemState {
        Normal,    // CR >= 150%
        Cautious,  // 130% <= CR < 150%
        Critical,  // 100% <= CR < 130%
        Emergency  // CR < 100%
    }

    // Structs
    struct MinimumAmounts {
        uint256 mintHypeMin;      // Minimum HYPE for minting
        uint256 redeemZusdMin;    // Minimum zUSD to redeem
        uint256 redeemZhypeMin;   // Minimum zHYPE to redeem
        uint256 swapZusdMin;      // Minimum zUSD to swap
        uint256 swapZhypeMin;     // Minimum zHYPE to swap
    }

    struct UserPosition {
        uint256 zusdBalance;
        uint256 zhypeBalance;
        uint256 hypeCollateral;
        uint256 lastUpdateTime;
    }

    struct ProtocolConfiguration {
        // Minimum amounts for protocol actions (18 decimals)
        uint256 mintHypeMin;          // Minimum HYPE required for minting
        uint256 redeemZusdMin;        // Minimum zUSD required for redemption
        uint256 redeemZhypeMin;       // Minimum zHYPE required for redemption
        uint256 swapZusdMin;          // Minimum zUSD required for swapping
        uint256 swapZhypeMin;         // Minimum zHYPE required for swapping
        uint256 kinetiqStakingMin;    // Kinetiq's minimum staking amount
    }

    /// @notice Fee configuration for a token type (basis points)
    struct TokenFees {
        uint16 mintHealthy;      // Fee when CR >= 150%
        uint16 mintCautious;     // Fee when 130% <= CR < 150%
        uint16 mintCritical;     // Fee when CR < 130%
        uint16 redeemHealthy;
        uint16 redeemCautious;
        uint16 redeemCritical;
    }

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
        uint256 accumulatedProtocolFees; // Fees accumulated by protocol (in kHYPE units)

        // Kinetiq integration (18 decimals)
        uint256 kinetiqExchangeRate;  // Current kHYPE/HYPE exchange rate

        // Swap rates (18 decimals) - how many tokens you get per 1 input token after fees
        uint256 zusdToZhypeRate;      // How many zHYPE per 1 zUSD (after fee)
        uint256 zhypeToZusdRate;      // How many zUSD per 1 zHYPE (after fee)

        // Leverage and APY metrics (per Hylo whitepaper)
        uint256 zhypeLeverage;        // Effective leverage = TotalReserves/zHYPE_MarketCap (1e18 = 1x)
        uint256 stabilityPoolAPY;     // APY = BaseYield x RevenueShare x StakingConcentration (basis points)

        // Metadata
        uint256 lastUpdated;          // Block timestamp of this snapshot
    }

    // Events
    event StablecoinMinted(address indexed user, uint256 hypAmount, uint256 zusdMinted, uint256 usdValueInvested);
    event LevercoinMinted(address indexed user, uint256 hypAmount, uint256 zhypeMinted, uint256 usdValueInvested);
    event SwapStableToLever(address indexed user, uint256 zusdAmount, uint256 zhypeReceived, uint256 usdValueSwapped);
    event SwapLeverToStable(address indexed user, uint256 zhypeAmount, uint256 zusdReceived, uint256 usdValueSwapped);
    event SystemStateChanged(uint8 newState);
    event EmergencyStateActivated(uint256 CR);
    event ProtocolFeeUpdated(uint256 healthy, uint256 cautious, uint256 critical);
    event FeesCollected(address indexed recipient, uint256 amount); // amount is in kHYPE units
    event CollateralRatioUpdated(uint256 newCR);
    event ProtocolIntervention(uint256 zusdAmount, uint256 zhypeMinted, uint256 currentCR);
    event RecoveryModeExited(uint256 zhypeBurned, uint256 zusdMinted, uint256 zhypeNav, uint256 zusdNav, uint256 currentCR);
    event NavUpdated(uint256 zusdNav, uint256 zhypeNav);
    event RedemptionQueued(address indexed user, uint256 redemptionId, uint256 tokenAmount, uint256 hypeAmount, bool isZusd, uint256 usdValueRedeemed);
    event RedemptionClaimed(address indexed user, uint256 redemptionId, uint256 hypeReceived, uint256 usdValueClaimed);
    event ReservesFunded(address indexed funder, uint256 hypeAmount, uint256 newTotalReserves, uint256 newCR);
    event HypeZionVaultSet(address indexed vault);

    // SwapRedeem events
    event SwapRedeemExecuted(
        address indexed user,
        uint8 tokenType,  // 0=zUSD, 1=zHYPE
        uint256 tokenAmount,
        uint256 kHypeSwapped,
        uint256 hypeReceived,  // Native HYPE received after swap
        uint256 feeCharged,
        uint256 usdValueRedeemed
    );
    event DexIntegrationSet(address indexed dexIntegration);
    event SwapRedeemConfigUpdated(uint256 feeBps, uint256 maxDivergenceBps);
    event SwapRedeemPausedStateChanged(bool paused);
    event SwapMintFeeUpdated(uint256 newFeeBps);
    event YieldSettlementQueued(uint256 indexed withdrawalId, uint256 yieldAmount);
    event TokenFeesUpdated(uint16[3] bullHypeMintFees, uint16[3] bullHypeRedeemFees, uint16[3] hzUsdMintFees, uint16[3] hzUsdRedeemFees);
    event InterventionManagerUpdated(address indexed oldManager, address indexed newManager);

    // Events for minimum amounts updates
    event MinimumAmountsUpdated(
        uint256 mintHypeMin,
        uint256 redeemZusdMin,
        uint256 redeemZhypeMin,
        uint256 swapZusdMin,
        uint256 swapZhypeMin
    );
    event MinimumAmountUpdated(uint8 actionType, uint256 amount);

    // Events for maximum limits updates
    event MaximumLimitsUpdated(uint256 maxTotalDeposit);
    event DepositTracked(address indexed user, uint256 amount, uint256 newTotal);

    // Custom errors
    error InsufficientBalance(uint256 requested, uint256 available);
    error MinimumStakingAmountNotMet(uint256 provided, uint256 minimum);
    error InvalidAmount(uint256 amount);
    error InvalidAddress();
    error InsufficientCollateral(uint256 required, uint256 available);
    error SystemInCriticalState();
    error EmergencyModeActive();
    error OraclePriceInvalid();
    error KinetiqUnavailable();
    error UnauthorizedAccess();
    error InsufficientReserve();
    error InsufficientReserves(uint256 requested, uint256 available);
    error IncorrectHYPEAmount();
    error BelowMinimumAmount();
    error MaximumDepositExceeded(uint256 requested, uint256 maximum);
    error CRNotLowEnough();
    error CRDroppedBelowThreshold(uint256 actual, uint256 required);
    error InsufficientInterventionAssets(uint256 requested, uint256 available);
    error WithdrawalNotReady();
    error AmountMismatch();
    error NoHYPEReceived();
    error HYPETransferFailed();
    error FeeTooHigh();
    error InvalidNAV();
    error AmountMustBeGreaterThanZero();
    error VaultNotSet();
    error InvalidSlippage();

    // SwapRedeem errors
    error SwapRedeemPaused();
    error DexIntegrationNotSet();
    error InsufficientOutput(uint256 received, uint256 minimum);
    error RateDivergenceTooHigh(uint256 divergenceBps, uint256 maxDivergenceBps);

    // Getters for public state variables (needed by HypeZionExchangeInformation)
    function oracle() external view returns (IOracle);
    function zusd() external view returns (HzUSD);
    function zhype() external view returns (BullHYPE);
    function stabilityPool() external view returns (IStabilityPool);
    function kinetiq() external view returns (IKinetiqIntegration);
    function protocolVersion() external view returns (string memory);
    function systemState() external view returns (SystemState);
    function totalHYPECollateral() external view returns (uint256);
    function totalKHYPEBalance() external view returns (uint256);
    function accumulatedFees() external view returns (uint256);
    function swapRedeemFeeBps() external view returns (uint256);

    // Core minting operations
    function mintStablecoin(uint256 amountHYPE, bytes calldata swapData) external payable returns (uint256 zusdMinted);
    function mintLevercoin(uint256 amountHYPE, bytes calldata swapData) external payable returns (uint256 zhypeMinted);

    // Redeem operations (returns redemptionId, not HYPE amount)
    function redeemStablecoin(uint256 zusdAmount) external returns (uint256 redemptionId);
    function redeemLevercoin(uint256 zhypeAmount) external returns (uint256 redemptionId);
    function claimRedemption(uint256 redemptionId) external returns (uint256 hypeReceived);

    // Redemption views
    function getUserRedemptions(address user) external view returns (uint256[] memory);
    function isRedemptionReady(uint256 redemptionId) external view returns (bool ready, uint256 timeRemaining);
    function getRedemptionDetails(uint256 redemptionId) external view returns (
        address requester,
        uint256 tokenAmount,
        uint256 expectedHype,
        bool isZusd,
        uint8 state
    );

    // SwapRedeem operations (instant redemption via DEX)
    function swapRedeemStablecoin(
        uint256 zusdAmount,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) external returns (uint256 hypeReceived);

    function swapRedeemLevercoin(
        uint256 zhypeAmount,
        bytes calldata encodedSwapData,
        uint256 minHypeOut
    ) external returns (uint256 hypeReceived);

    // NAV calculations
    function getZusdNavInHYPE() external view returns (uint256 nav);
    function getZhypeNavInHYPE() external view returns (uint256 nav);
    function getSzUSDNavInUSD() external view returns (uint256);
    function getTotalReserveInHYPE() external view returns (uint256);
    function getAvailableReserveInHYPE() external view returns (uint256);
    function getZusdLiabilitiesInHYPE() external view returns (uint256);
    function getVaultKHYPEBalance() external view returns (uint256);

    // System management
    function getSystemCR() external view returns (uint256);
    function getProtocolFee(bool isZusd, bool isMint) external view returns (uint256);
    function getMinimumAmounts() external view returns (MinimumAmounts memory);
    function updateSystemState() external;

    // Token-specific fee getters
    function bullHYPEFees() external view returns (TokenFees memory);
    function hzUSDFees() external view returns (TokenFees memory);

    // Admin functions
    function collectFees(address recipient) external;
    function setProtocolVersion(string calldata version) external;
    function pause() external;
    function unpause() external;
    function setSwapRedeemPaused(bool paused) external;
    function withdrawKHYPEForYield(uint256 k) external;

    // Minimum amounts management
    function setMinimumAmounts(
        uint256 _mintHypeMin,
        uint256 _redeemZusdMin,
        uint256 _redeemZhypeMin,
        uint256 _swapZusdMin,
        uint256 _swapZhypeMin
    ) external;

    // Maximum limits management
    function setMaximumLimits(uint256 _maxTotalDeposit) external;

    // Fee configuration management
    function setTokenFees(uint16[3] calldata bullHypeMintFees, uint16[3] calldata bullHypeRedeemFees, uint16[3] calldata hzUsdMintFees, uint16[3] calldata hzUsdRedeemFees) external;

    // Intervention management
    function interventionManager() external view returns (address);
    function setInterventionManager(address _interventionManager) external;
    function interventionBurn(address from, uint256 amount, bool isZusd) external;
    function interventionMint(address to, uint256 amount, bool isZusd) external;

}
