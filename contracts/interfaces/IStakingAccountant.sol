// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IStakingAccountant {
    function recordStake(address user, uint256 amount) external;
    function recordUnstake(address user, uint256 amount) external;
    function recordRewards(address user, uint256 amount) external;
    function recordClaim(uint256 amount) external;
    function getUserStats(address user) external view returns (uint256 totalStaked, uint256 totalRewards);
    function HYPEToKHYPE(uint256 amount) external view returns (uint256);
    function kHYPEToHYPE(uint256 amount) external view returns (uint256);
}
