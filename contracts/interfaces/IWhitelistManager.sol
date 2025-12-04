// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IWhitelistManager {
    function isWhitelisted(address account) external view returns (bool);
    function addToWhitelist(address account) external;
    function removeFromWhitelist(address account) external;
}