// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IStakingPool {
    function stakingManagerImpl() external view returns (address);
    function owner() external view returns (address);
}
