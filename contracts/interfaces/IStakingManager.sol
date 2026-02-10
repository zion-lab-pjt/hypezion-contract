// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IStakingManager {
    function stake(address recipient) external payable returns (uint256);
    function unstake(uint256 shares) external returns (uint256);
    function claim(address recipient) external returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}
