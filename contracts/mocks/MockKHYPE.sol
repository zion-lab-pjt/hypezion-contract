// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MockKHYPE
 * @notice Mock kHYPE token for testing Vault integration
 * @dev Simple ERC20 with mint capability for testing
 */
contract MockKHYPE is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Events
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    // Errors
    error UnauthorizedMinter(address caller);

    constructor() ERC20("Mock kHYPE", "mkHYPE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Add a minter
     * @param minter Address to add as minter
     */
    function addMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
        emit MinterAdded(minter);
    }

    /**
     * @notice Remove a minter
     * @param minter Address to remove as minter
     */
    function removeMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
        emit MinterRemoved(minter);
    }

    /**
     * @notice Mint mkHYPE tokens (admin or approved minters)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(MINTER_ROLE, msg.sender)) {
            revert UnauthorizedMinter(msg.sender);
        }
        _mint(to, amount);
    }

    /**
     * @notice Burn mkHYPE tokens
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
