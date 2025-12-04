// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title HyloAccessControl
 * @notice Centralized access control for the Hylo protocol
 * @dev Defines and manages all protocol roles
 */
contract HyloAccessControl is AccessControlEnumerable, Pausable {
    // Role definitions
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    // Role member limits
    mapping(bytes32 => uint256) public roleMaxMembers;
    
    // Role permissions tracking
    mapping(bytes32 => mapping(address => bool)) public contractPermissions;
    
    // Emergency contacts
    address[] public emergencyContacts;
    mapping(address => bool) public isEmergencyContact;
    
    // Events
    event RoleGrantedWithExpiry(bytes32 indexed role, address indexed account, uint256 expiryTime);
    event RoleMaxMembersUpdated(bytes32 indexed role, uint256 oldMax, uint256 newMax);
    event ContractPermissionGranted(bytes32 indexed role, address indexed contractAddress);
    event ContractPermissionRevoked(bytes32 indexed role, address indexed contractAddress);
    event EmergencyContactAdded(address indexed contact);
    event EmergencyContactRemoved(address indexed contact);
    event EmergencyActionExecuted(address indexed executor, string action);
    
    // Errors
    error RoleMemberLimitExceeded();
    error InvalidRoleConfiguration();
    error UnauthorizedContract();
    error NotEmergencyContact();
    error InvalidAddress();
    
    // Modifiers
    modifier onlyEmergency() {
        if (!isEmergencyContact[msg.sender]) revert NotEmergencyContact();
        _;
    }
    
    modifier contractAuthorized(bytes32 role) {
        if (!contractPermissions[role][msg.sender]) revert UnauthorizedContract();
        _;
    }
    
    constructor() {
        // Grant admin role to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Set up role hierarchy
        _setRoleAdmin(OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(HARVESTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ORACLE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(TREASURY_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(RISK_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, DEFAULT_ADMIN_ROLE);
        
        // Set default max members
        roleMaxMembers[OPERATOR_ROLE] = 5;
        roleMaxMembers[HARVESTER_ROLE] = 3;
        roleMaxMembers[PAUSER_ROLE] = 3;
        roleMaxMembers[ORACLE_ROLE] = 5;
        roleMaxMembers[TREASURY_ROLE] = 3;
        roleMaxMembers[RISK_MANAGER_ROLE] = 3;
        roleMaxMembers[UPGRADER_ROLE] = 2;
        
        // Grant initial roles
        _grantRole(PAUSER_ROLE, msg.sender);
        
        // Add deployer as emergency contact
        emergencyContacts.push(msg.sender);
        isEmergencyContact[msg.sender] = true;
    }
    
    /**
     * @notice Grant role with validation
     * @param role Role to grant
     * @param account Account to grant role to
     */
    function grantRoleWithLimit(bytes32 role, address account) 
        public 
        onlyRole(getRoleAdmin(role)) 
    {
        if (account == address(0)) revert InvalidAddress();
        
        // Check member limit
        if (roleMaxMembers[role] > 0 && getRoleMemberCount(role) >= roleMaxMembers[role]) {
            revert RoleMemberLimitExceeded();
        }
        
        _grantRole(role, account);
    }
    
    /**
     * @notice Revoke role safely
     * @param role Role to revoke
     * @param account Account to revoke role from
     */
    function revokeRoleSafely(bytes32 role, address account) 
        public 
        onlyRole(getRoleAdmin(role)) 
    {
        _revokeRole(role, account);
    }
    
    /**
     * @notice Grant contract permission for a role
     * @param role Role to grant permission to
     * @param contractAddress Contract address to authorize
     */
    function grantContractPermission(bytes32 role, address contractAddress) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (contractAddress == address(0)) revert InvalidAddress();
        
        contractPermissions[role][contractAddress] = true;
        emit ContractPermissionGranted(role, contractAddress);
    }
    
    /**
     * @notice Revoke contract permission for a role
     * @param role Role to revoke permission from
     * @param contractAddress Contract address to deauthorize
     */
    function revokeContractPermission(bytes32 role, address contractAddress) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        contractPermissions[role][contractAddress] = false;
        emit ContractPermissionRevoked(role, contractAddress);
    }
    
    /**
     * @notice Update maximum members for a role
     * @param role Role to update
     * @param newMax New maximum number of members
     */
    function setRoleMaxMembers(bytes32 role, uint256 newMax) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 oldMax = roleMaxMembers[role];
        roleMaxMembers[role] = newMax;
        emit RoleMaxMembersUpdated(role, oldMax, newMax);
    }
    
    /**
     * @notice Add emergency contact
     * @param contact Address to add as emergency contact
     */
    function addEmergencyContact(address contact) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (contact == address(0)) revert InvalidAddress();
        if (isEmergencyContact[contact]) return;
        
        emergencyContacts.push(contact);
        isEmergencyContact[contact] = true;
        emit EmergencyContactAdded(contact);
    }
    
    /**
     * @notice Remove emergency contact
     * @param contact Address to remove from emergency contacts
     */
    function removeEmergencyContact(address contact) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (!isEmergencyContact[contact]) return;
        
        isEmergencyContact[contact] = false;
        
        // Remove from array
        for (uint256 i = 0; i < emergencyContacts.length; i++) {
            if (emergencyContacts[i] == contact) {
                emergencyContacts[i] = emergencyContacts[emergencyContacts.length - 1];
                emergencyContacts.pop();
                break;
            }
        }
        
        emit EmergencyContactRemoved(contact);
    }
    
    /**
     * @notice Pause protocol operations
     * @dev Can be called by PAUSER_ROLE or emergency contacts
     */
    function pause() external {
        require(
            hasRole(PAUSER_ROLE, msg.sender) || isEmergencyContact[msg.sender],
            "Not authorized to pause"
        );
        _pause();
        
        if (isEmergencyContact[msg.sender]) {
            emit EmergencyActionExecuted(msg.sender, "pause");
        }
    }
    
    /**
     * @notice Unpause protocol operations
     * @dev Can only be called by DEFAULT_ADMIN_ROLE
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency role grant
     * @param role Role to grant
     * @param account Account to grant role to
     * @dev Can only be called by emergency contacts in paused state
     */
    function emergencyGrantRole(bytes32 role, address account) 
        external 
        onlyEmergency 
        whenPaused 
    {
        if (account == address(0)) revert InvalidAddress();
        
        // Don't check member limits in emergency
        
        _grantRole(role, account);
        emit EmergencyActionExecuted(msg.sender, "emergencyGrantRole");
    }
    
    /**
     * @notice Emergency role revoke
     * @param role Role to revoke
     * @param account Account to revoke role from
     * @dev Can only be called by emergency contacts in paused state
     */
    function emergencyRevokeRole(bytes32 role, address account) 
        external 
        onlyEmergency 
        whenPaused 
    {
        // Remove role
        
        _revokeRole(role, account);
        emit EmergencyActionExecuted(msg.sender, "emergencyRevokeRole");
    }
    
    /**
     * @notice Get all members of a role
     * @param role Role to query
     * @return members Array of addresses with the role
     */
    function getRoleMembers(bytes32 role) public view override returns (address[] memory members) {
        uint256 memberCount = getRoleMemberCount(role);
        members = new address[](memberCount);
        
        for (uint256 i = 0; i < memberCount; i++) {
            members[i] = getRoleMember(role, i);
        }
        
        return members;
    }
    
    /**
     * @notice Check if account has any admin role
     * @param account Account to check
     * @return hasAdmin Whether account has admin privileges
     */
    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
    
    /**
     * @notice Check if account has operational role
     * @param account Account to check
     * @return hasOps Whether account has operational privileges
     */
    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }
    
    /**
     * @notice Get all emergency contacts
     * @return contacts Array of emergency contact addresses
     */
    function getEmergencyContacts() external view returns (address[] memory) {
        return emergencyContacts;
    }
    
    /**
     * @notice Check multiple roles for an account
     * @param account Account to check
     * @param roles Array of roles to check
     * @return hasRoles Array of booleans indicating role membership
     */
    function checkMultipleRoles(address account, bytes32[] calldata roles) 
        external 
        view 
        returns (bool[] memory hasRoles) 
    {
        hasRoles = new bool[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            hasRoles[i] = hasRole(roles[i], account);
        }
        return hasRoles;
    }
    
    /**
     * @notice Get role configuration
     * @param role Role to query
     * @return admin Role admin
     * @return maxMembers Maximum members allowed
     * @return currentMembers Current member count
     */
    function getRoleConfig(bytes32 role) external view returns (
        bytes32 admin,
        uint256 maxMembers,
        uint256 currentMembers
    ) {
        admin = getRoleAdmin(role);
        maxMembers = roleMaxMembers[role];
        currentMembers = getRoleMemberCount(role);
    }
}