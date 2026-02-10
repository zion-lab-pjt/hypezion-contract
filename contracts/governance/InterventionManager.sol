// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IInterventionManager.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../interfaces/IStabilityPool.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";

/**
 * @title InterventionManager
 * @notice Manages protocol interventions to maintain healthy collateral ratio
 * @dev Extracted from HypeZionExchange to reduce bytecode size
 * @dev Handles CR-based interventions: trigger intervention when CR < 130%, exit recovery when CR >= 150%
 */
contract InterventionManager is
    IInterventionManager,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ==================
    // === CONSTANTS ====
    // ==================

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    /// @notice CR threshold for triggering intervention (130%)
    uint256 public constant CAUTIOUS_CR_THRESHOLD = 13000;

    /// @notice CR threshold for exiting recovery mode (150%)
    uint256 public constant NORMAL_CR_THRESHOLD = 15000;

    /// @notice Target CR after intervention (140% - provides 10% buffer above 130%)
    uint256 public constant TARGET_INTERVENTION_CR = 14000;

    /// @notice Initial NAV for zHYPE when no supply exists
    uint256 public constant INITIAL_ZHYPE_NAV = 1e18;

    // =======================
    // === CONTRACT REFS =====
    // =======================

    /// @notice Reference to the main exchange contract
    IHypeZionExchange public exchange;

    /// @notice Reference to hzUSD token
    HzUSD public zusd;

    /// @notice Reference to bullHYPE token
    BullHYPE public zhype;

    /// @notice Reference to stability pool
    IStabilityPool public stabilityPool;

    // =======================
    // === STORAGE GAP ======
    // =======================

    uint256[50] private __gap;

    // =======================
    // === CONSTRUCTOR ======
    // =======================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =======================
    // === INITIALIZER ======
    // =======================

    /**
     * @notice Initialize the InterventionManager
     * @param _exchange Address of the HypeZionExchange contract
     * @param _zusd Address of the hzUSD token
     * @param _zhype Address of the bullHYPE token
     * @param _stabilityPool Address of the stability pool
     */
    function initialize(
        address _exchange,
        address _zusd,
        address _zhype,
        address _stabilityPool
    ) external initializer {
        if (_exchange == address(0)) revert ZeroAddress();
        if (_zusd == address(0)) revert ZeroAddress();
        if (_zhype == address(0)) revert ZeroAddress();
        if (_stabilityPool == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        exchange = IHypeZionExchange(_exchange);
        zusd = HzUSD(_zusd);
        zhype = BullHYPE(_zhype);
        stabilityPool = IStabilityPool(_stabilityPool);
    }

    // ==============================
    // === INTERVENTION FUNCTIONS ===
    // ==============================

    /**
     * @notice Trigger protocol intervention to restore CR to 140%
     * @dev Permissionless - anyone can call when CR < 130%
     * @dev Burns hzUSD from stability pool and mints hzHYPE to stability pool
     * @return zusdBurned Amount of hzUSD burned during intervention
     * @return zhypeMinted Amount of hzHYPE minted during intervention
     */
    function triggerIntervention()
        external
        nonReentrant
        returns (uint256 zusdBurned, uint256 zhypeMinted)
    {
        uint256 crBefore = exchange.getSystemCR();

        // Block intervention in Emergency state - would make things worse
        if (exchange.systemState() == IHypeZionExchange.SystemState.Emergency) {
            revert EmergencyModeActive();
        }

        if (crBefore >= CAUTIOUS_CR_THRESHOLD) {
            revert CRNotLowEnough(crBefore, CAUTIOUS_CR_THRESHOLD);
        }

        // Calculate exact amount needed to restore CR to 140% (10% buffer above 130% critical threshold)
        (zusdBurned, zhypeMinted) = _calculateInterventionAmounts();

        // Validate amount doesn't exceed available assets in stability pool
        uint256 availableForIntervention = zusd.balanceOf(address(stabilityPool));
        if (zusdBurned > availableForIntervention) {
            revert InsufficientInterventionAssets(zusdBurned, availableForIntervention);
        }

        // Execute token operations via Exchange (Exchange has mint/burn permissions)
        // Burn hzUSD from stability pool (decreases liability)
        exchange.interventionBurn(address(stabilityPool), zusdBurned, true);

        // Mint hzHYPE to stability pool (increases equity)
        exchange.interventionMint(address(stabilityPool), zhypeMinted, false);

        // Update stability pool's internal accounting
        stabilityPool.protocolIntervention(zusdBurned, zhypeMinted);

        // Update system state to reflect new CR
        exchange.updateSystemState();

        uint256 crAfter = exchange.getSystemCR();

        emit InterventionTriggered(zusdBurned, zhypeMinted, crBefore, crAfter);
    }

    /**
     * @notice Exit recovery mode when CR becomes healthy (>= 150%)
     * @dev Permissionless - anyone can call when CR >= 150% and pool has hzHYPE
     * @dev Burns hzHYPE from stability pool and mints hzUSD to stability pool
     * @param minZusdOut Minimum zUSD to mint (0 for no slippage protection)
     * @return zhypeBurned Amount of hzHYPE burned
     * @return zusdMinted Amount of hzUSD minted
     */
    function exitRecoveryMode(uint256 minZusdOut)
        external
        nonReentrant
        returns (uint256 zhypeBurned, uint256 zusdMinted)
    {
        uint256 crBefore = exchange.getSystemCR();

        if (crBefore < NORMAL_CR_THRESHOLD) {
            revert CRNotHighEnough(crBefore, NORMAL_CR_THRESHOLD);
        }

        zhypeBurned = stabilityPool.hzhypeInPool();
        if (zhypeBurned == 0) {
            revert NoZhypeInPool();
        }

        // Calculate equivalent zUSD amount using current NAV values
        uint256 zhypeNav = exchange.getZhypeNavInHYPE();
        uint256 zusdNav = exchange.getZusdNavInHYPE();

        if (zusdNav == 0) revert InvalidNAV();

        zusdMinted = (zhypeBurned * zhypeNav) / zusdNav;

        if (minZusdOut > 0 && zusdMinted < minZusdOut) {
            revert InsufficientOutput(zusdMinted, minZusdOut);
        }

        // Execute token operations via Exchange (Exchange has mint/burn permissions)
        // Burn hzHYPE from stability pool
        exchange.interventionBurn(address(stabilityPool), zhypeBurned, false);

        // Mint hzUSD to stability pool
        exchange.interventionMint(address(stabilityPool), zusdMinted, true);

        // Update stability pool accounting
        stabilityPool.exitRecoveryMode(zhypeBurned, zusdMinted);

        // Update system state to reflect new CR
        exchange.updateSystemState();

        uint256 crAfter = exchange.getSystemCR();
        if (crAfter < NORMAL_CR_THRESHOLD) {
            revert CRDroppedBelowThreshold(crAfter, NORMAL_CR_THRESHOLD);
        }

        emit RecoveryModeExited(zhypeBurned, zusdMinted, zhypeNav, zusdNav, crAfter);
    }

    // ==============================
    // === VIEW FUNCTIONS ===========
    // ==============================

    /**
     * @notice Calculate the amounts needed for intervention
     * @return zusdNeeded Amount of zUSD tokens to burn
     * @return estimatedZhype Estimated zHYPE to be minted
     */
    function calculateInterventionAmount()
        external
        view
        returns (uint256 zusdNeeded, uint256 estimatedZhype)
    {
        return _calculateInterventionAmounts();
    }

    /**
     * @notice Check if intervention can be triggered
     * @return canIntervene True if CR is below threshold and assets available
     * @return reason Reason string if cannot intervene
     */
    function canTriggerIntervention()
        external
        view
        returns (bool canIntervene, string memory reason)
    {
        // Check emergency state
        if (exchange.systemState() == IHypeZionExchange.SystemState.Emergency) {
            return (false, "Emergency mode active");
        }

        // Check CR threshold
        uint256 cr = exchange.getSystemCR();
        if (cr >= CAUTIOUS_CR_THRESHOLD) {
            return (false, "CR above threshold");
        }

        // Check available assets
        (uint256 zusdNeeded, ) = _calculateInterventionAmounts();
        uint256 available = zusd.balanceOf(address(stabilityPool));
        if (zusdNeeded > available) {
            return (false, "Insufficient stability pool assets");
        }

        return (true, "");
    }

    /**
     * @notice Check if recovery mode can be exited
     * @return canExit True if CR is above threshold and zhype exists in pool
     * @return zhypeInPool Amount of zhype in stability pool
     */
    function canExitRecoveryMode()
        external
        view
        returns (bool canExit, uint256 zhypeInPool)
    {
        zhypeInPool = stabilityPool.hzhypeInPool();

        if (exchange.getSystemCR() < NORMAL_CR_THRESHOLD) {
            return (false, zhypeInPool);
        }

        if (zhypeInPool == 0) {
            return (false, 0);
        }

        return (true, zhypeInPool);
    }

    // ==============================
    // === INTERNAL FUNCTIONS =======
    // ==============================

    /**
     * @notice Calculate intervention amounts
     * @dev Formula: current_liabilities_in_HYPE - current_reserves_in_HYPE/1.4
     * @return zusdTokensToBurn Amount of zUSD tokens to burn
     * @return zhypeToMint Amount of zHYPE to mint
     */
    function _calculateInterventionAmounts()
        internal
        view
        returns (uint256 zusdTokensToBurn, uint256 zhypeToMint)
    {
        uint256 currentReservesInHYPE = exchange.getTotalReserveInHYPE();
        uint256 currentLiabilitiesInHYPE = exchange.getZusdLiabilitiesInHYPE();

        // Liability reduction needed to reach 140% CR (provides buffer before becoming critical again)
        // liabilityReduction = liabilities - reserves/1.4
        uint256 liabilityReduction = currentLiabilitiesInHYPE -
            (currentReservesInHYPE * BASIS_POINTS) / TARGET_INTERVENTION_CR;

        // Convert liability reduction (in HYPE) to zusd tokens to burn
        uint256 zusdNav = exchange.getZusdNavInHYPE();
        zusdTokensToBurn = (liabilityReduction * PRECISION) / zusdNav;

        // Calculate zhype to mint
        zhypeToMint = _calculateZhypeToMint(zusdTokensToBurn, zusdNav, currentReservesInHYPE, currentLiabilitiesInHYPE);
    }

    /**
     * @notice Calculate zHYPE amount to mint for intervention
     * @dev Maintains value equivalence: value of minted zhype = value of burned zusd
     * @param zusdAmount Amount of zusd being burned
     * @param zusdNav NAV of zusd in HYPE
     * @param reserves Current reserves in HYPE
     * @param liabilities Current liabilities in HYPE
     * @return zhypeAmount Amount of zHYPE to mint
     */
    function _calculateZhypeToMint(
        uint256 zusdAmount,
        uint256 zusdNav,
        uint256 reserves,
        uint256 liabilities
    ) internal view returns (uint256 zhypeAmount) {
        uint256 zhypeSupply = zhype.totalSupply();

        if (zhypeSupply == 0) {
            // If no zhype exists yet, mint at initial NAV maintaining value equivalence
            // Value burned (in HYPE) = zusdAmount * zusdNav
            // zhypeAmount = value_burned / INITIAL_ZHYPE_NAV
            zhypeAmount = (zusdAmount * zusdNav) / INITIAL_ZHYPE_NAV;
        } else {
            // Calculate zHYPE to mint maintaining value equivalence
            // Formula: (zusdAmount * zusdNav * current_zhype_supply) / (PRECISION * current_zhype_equity)
            uint256 currentZhypeEquity = reserves - liabilities;

            // Value of minted zhype = value of burned zusd
            zhypeAmount = (zusdAmount * zusdNav * zhypeSupply) / (PRECISION * currentZhypeEquity);
        }
    }

    // ==============================
    // === ADMIN FUNCTIONS ==========
    // ==============================

    /**
     * @notice Update the exchange contract reference
     * @param _exchange New exchange contract address
     */
    function setExchange(address _exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_exchange == address(0)) revert ZeroAddress();
        address oldExchange = address(exchange);
        exchange = IHypeZionExchange(_exchange);
        emit ExchangeUpdated(oldExchange, _exchange);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
