// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IInterventionManager
 * @notice Interface for the protocol intervention manager
 * @dev Handles CR-based interventions to restore system health
 */
interface IInterventionManager {
    // ==================
    // === EVENTS =======
    // ==================

    /// @notice Emitted when intervention is triggered to restore CR
    event InterventionTriggered(
        uint256 zusdBurned,
        uint256 zhypeMinted,
        uint256 crBefore,
        uint256 crAfter
    );

    /// @notice Emitted when recovery mode is exited
    event RecoveryModeExited(
        uint256 zhypeBurned,
        uint256 zusdMinted,
        uint256 zhypeNav,
        uint256 zusdNav,
        uint256 crAfter
    );

    /// @notice Emitted when exchange contract is updated
    event ExchangeUpdated(address indexed oldExchange, address indexed newExchange);

    // ==================
    // === ERRORS =======
    // ==================

    /// @notice CR is not low enough to trigger intervention
    error CRNotLowEnough(uint256 currentCR, uint256 threshold);

    /// @notice CR is not high enough to exit recovery mode
    error CRNotHighEnough(uint256 currentCR, uint256 threshold);

    /// @notice Emergency mode is active, intervention blocked
    error EmergencyModeActive();

    /// @notice Insufficient assets in stability pool for intervention
    error InsufficientInterventionAssets(uint256 required, uint256 available);

    /// @notice No zhype in stability pool to exit recovery
    error NoZhypeInPool();

    /// @notice Invalid NAV value (zero)
    error InvalidNAV();

    /// @notice Output below minimum threshold
    error InsufficientOutput(uint256 received, uint256 minimum);

    /// @notice CR dropped below threshold after operation
    error CRDroppedBelowThreshold(uint256 actual, uint256 required);

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Caller is not authorized
    error UnauthorizedCaller(address caller);

    // ==================
    // === FUNCTIONS ====
    // ==================

    /**
     * @notice Trigger protocol intervention to restore CR to target threshold
     * @dev Permissionless - anyone can call when CR < CAUTIOUS_CR_THRESHOLD (130%)
     * @dev Automatically calculates and converts hzUSD from stability pool to hzHYPE
     * @return zusdBurned Amount of hzUSD burned during intervention
     * @return zhypeMinted Amount of hzHYPE minted during intervention
     */
    function triggerIntervention() external returns (uint256 zusdBurned, uint256 zhypeMinted);

    /**
     * @notice Exit recovery mode when CR becomes healthy
     * @dev Permissionless - anyone can call when CR >= NORMAL_CR_THRESHOLD (150%)
     * @dev Converts hzHYPE back to hzUSD in stability pool, restoring single-asset state
     * @param minZusdOut Minimum zUSD to mint (0 for no slippage protection)
     * @return zhypeBurned Amount of hzHYPE burned
     * @return zusdMinted Amount of hzUSD minted
     */
    function exitRecoveryMode(uint256 minZusdOut) external returns (uint256 zhypeBurned, uint256 zusdMinted);

    /**
     * @notice Calculate the amount needed to restore CR to target
     * @dev View function to preview intervention amounts
     * @return zusdNeeded Amount of zUSD tokens to burn
     * @return estimatedZhype Estimated zHYPE to be minted
     */
    function calculateInterventionAmount() external view returns (uint256 zusdNeeded, uint256 estimatedZhype);

    /**
     * @notice Check if intervention can be triggered
     * @return canIntervene True if CR is below threshold and assets available
     * @return reason Reason string if cannot intervene
     */
    function canTriggerIntervention() external view returns (bool canIntervene, string memory reason);

    /**
     * @notice Check if recovery mode can be exited
     * @return canExit True if CR is above threshold and zhype exists in pool
     * @return zhypeInPool Amount of zhype in stability pool
     */
    function canExitRecoveryMode() external view returns (bool canExit, uint256 zhypeInPool);
}
