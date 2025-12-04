// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IValidatorManager {
    function addDistribution(uint256 amount) external;
    function validatorBalance() external view returns (uint256);
    function totalBalance() external view returns (uint256);
    function validatorShares(address validator) external view returns (uint256);
    function totalRewards() external view returns (uint256);
    function getDelegation(address account) external view returns (address);
    function validatorActiveState(address validator) external view returns (bool);
}