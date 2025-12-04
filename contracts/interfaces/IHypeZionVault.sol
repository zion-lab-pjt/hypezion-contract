// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IHypeZionVault
 * @notice Interface for HypeZion Protocol's kHYPE reserve vault
 * @dev Pure ERC-4626 vault interface with security features
 */
interface IHypeZionVault is IERC4626 {
    // View functions
    function getRemainingCapacity(address user) external view returns (uint256);

    // Admin functions
    function setWithdrawalLimit(address target, uint256 limit, uint256 windowSize) external;

    // Emergency controls
    function pause() external;
    function unpause() external;
}
