// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPauserRegistry {
    function isPaused(address account) external view returns (bool);
    function isPauser(address account) external view returns (bool);
    function addPauser(address account) external;
    function removePauser(address account) external;
}