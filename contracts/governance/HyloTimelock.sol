// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title HyloTimelock
 * @notice Timelock controller with emergency pause functionality
 * @dev Extends OpenZeppelin's TimelockController with protocol-specific features
 */
contract HyloTimelock is TimelockController, Pausable {
    // Define admin role constant (TimelockController uses this)
    bytes32 public constant TIMELOCK_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    
    // Custom delay configurations
    mapping(bytes4 => uint256) public functionDelays;
    uint256 public emergencyDelay = 6 hours;
    uint256 public criticalDelay = 48 hours;
    uint256 public standardDelay = 24 hours;
    
    // Operation categories
    enum OperationCategory {
        Standard,
        Critical,
        Emergency
    }
    
    mapping(bytes32 => OperationCategory) public operationCategories;
    
    // Emergency bypass
    mapping(address => bool) public emergencyBypassEnabled;
    uint256 public emergencyBypassExpiry;
    
    // Events
    event FunctionDelaySet(bytes4 indexed selector, uint256 delay);
    event OperationCategorized(bytes32 indexed id, OperationCategory category);
    event EmergencyBypassActivated(address indexed activator, uint256 expiry);
    event EmergencyBypassDeactivated(address indexed deactivator);
    event DelayUpdated(string delayType, uint256 oldDelay, uint256 newDelay);
    
    // Errors
    error InvalidDelay();
    error EmergencyBypassActive();
    error EmergencyBypassExpired();
    error UnauthorizedEmergencyAction();
    
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        standardDelay = minDelay;
    }
    
    /**
     * @notice Schedule an operation with category-based delay
     * @param target Target contract address
     * @param value ETH value to send
     * @param data Function call data
     * @param predecessor Predecessor operation ID
     * @param salt Operation salt
     * @param delay Custom delay (0 to use default)
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        
        // Determine delay based on category or function
        uint256 actualDelay = _determineDelay(id, data, delay);
        
        // Schedule with determined delay using parent function
        super.schedule(target, value, data, predecessor, salt, actualDelay);
    }
    
    /**
     * @notice Schedule batch operation with category-based delay
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        require(targets.length == values.length, "TimelockController: length mismatch");
        require(targets.length == payloads.length, "TimelockController: length mismatch");
        
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        
        // Use highest required delay for batch
        uint256 actualDelay = delay;
        for (uint256 i = 0; i < payloads.length; i++) {
            uint256 requiredDelay = _determineDelay(id, payloads[i], 0);
            if (requiredDelay > actualDelay) {
                actualDelay = requiredDelay;
            }
        }
        
        super.scheduleBatch(targets, values, payloads, predecessor, salt, actualDelay);
    }
    
    /**
     * @notice Execute operation with emergency bypass check
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override onlyRoleOrOpenRole(EXECUTOR_ROLE) {
        // Check for emergency bypass
        if (_isEmergencyBypassActive()) {
            _executeEmergency(target, value, data);
            return;
        }
        
        super.execute(target, value, data, predecessor, salt);
    }
    
    /**
     * @notice Set operation category
     * @param id Operation ID
     * @param category Operation category
     */
    function setOperationCategory(bytes32 id, OperationCategory category) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        operationCategories[id] = category;
        emit OperationCategorized(id, category);
    }
    
    /**
     * @notice Set custom delay for specific function
     * @param selector Function selector
     * @param delay Delay in seconds
     */
    function setFunctionDelay(bytes4 selector, uint256 delay) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        if (delay > 7 days) revert InvalidDelay();
        
        functionDelays[selector] = delay;
        emit FunctionDelaySet(selector, delay);
    }
    
    /**
     * @notice Activate emergency bypass
     * @param duration Duration of bypass in seconds
     */
    function activateEmergencyBypass(uint256 duration) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
        whenPaused 
    {
        if (duration > 24 hours) revert InvalidDelay();
        
        emergencyBypassExpiry = block.timestamp + duration;
        emergencyBypassEnabled[msg.sender] = true;
        
        emit EmergencyBypassActivated(msg.sender, emergencyBypassExpiry);
    }
    
    /**
     * @notice Deactivate emergency bypass
     */
    function deactivateEmergencyBypass() 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        emergencyBypassExpiry = 0;
        emergencyBypassEnabled[msg.sender] = false;
        
        emit EmergencyBypassDeactivated(msg.sender);
    }
    
    /**
     * @notice Pause timelock operations
     */
    function pause() external onlyRole(TIMELOCK_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause timelock operations
     */
    function unpause() external onlyRole(TIMELOCK_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Update standard delay
     * @param newDelay New delay in seconds
     */
    function updateStandardDelay(uint256 newDelay) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        if (newDelay < 6 hours || newDelay > 7 days) revert InvalidDelay();
        
        uint256 oldDelay = standardDelay;
        standardDelay = newDelay;
        
        emit DelayUpdated("standard", oldDelay, newDelay);
    }
    
    /**
     * @notice Update critical delay
     * @param newDelay New delay in seconds
     */
    function updateCriticalDelay(uint256 newDelay) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        if (newDelay < 24 hours || newDelay > 7 days) revert InvalidDelay();
        
        uint256 oldDelay = criticalDelay;
        criticalDelay = newDelay;
        
        emit DelayUpdated("critical", oldDelay, newDelay);
    }
    
    /**
     * @notice Update emergency delay
     * @param newDelay New delay in seconds
     */
    function updateEmergencyDelay(uint256 newDelay) 
        external 
        onlyRole(TIMELOCK_ADMIN_ROLE) 
    {
        if (newDelay < 1 hours || newDelay > 24 hours) revert InvalidDelay();
        
        uint256 oldDelay = emergencyDelay;
        emergencyDelay = newDelay;
        
        emit DelayUpdated("emergency", oldDelay, newDelay);
    }
    
    /**
     * @notice Get operation details
     * @param id Operation ID
     * @return timestamp Ready timestamp
     * @return category Operation category
     * @return isReady Whether operation is ready
     * @return isDone Whether operation is done
     */
    function getOperationDetails(bytes32 id) external view returns (
        uint256 timestamp,
        OperationCategory category,
        bool isReady,
        bool isDone
    ) {
        timestamp = getTimestamp(id);
        category = operationCategories[id];
        isReady = isOperationReady(id);
        isDone = isOperationDone(id);
    }
    
    /**
     * @notice Determine delay for operation
     * @param id Operation ID
     * @param data Call data
     * @param customDelay Custom delay if specified
     * @return delay Actual delay to use
     */
    function _determineDelay(
        bytes32 id,
        bytes calldata data,
        uint256 customDelay
    ) private view returns (uint256) {
        // Use custom delay if specified
        if (customDelay > 0) {
            return customDelay;
        }
        
        // Check function-specific delay
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            uint256 functionDelay = functionDelays[selector];
            if (functionDelay > 0) {
                return functionDelay;
            }
        }
        
        // Check operation category
        OperationCategory category = operationCategories[id];
        if (category == OperationCategory.Emergency) {
            return emergencyDelay;
        } else if (category == OperationCategory.Critical) {
            return criticalDelay;
        }
        
        // Default to standard delay
        return standardDelay;
    }
    
    /**
     * @notice Check if emergency bypass is active
     * @return active Whether bypass is active
     */
    function _isEmergencyBypassActive() private view returns (bool) {
        return emergencyBypassExpiry > block.timestamp && 
               emergencyBypassEnabled[msg.sender];
    }
    
    /**
     * @notice Execute operation under emergency bypass
     * @param target Target address
     * @param value ETH value
     * @param data Call data
     */
    function _executeEmergency(
        address target,
        uint256 value,
        bytes calldata data
    ) private {
        if (!_isEmergencyBypassActive()) revert EmergencyBypassExpired();
        
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        Address.verifyCallResult(success, returndata);
    }
    
    /**
     * @notice Check if delay is within acceptable range
     * @param delay Delay to check
     * @return valid Whether delay is valid
     */
    function isValidDelay(uint256 delay) public pure returns (bool) {
        return delay >= 1 hours && delay <= 7 days;
    }
}