// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IKinetiqIntegration {
    // Events
    event HYPEStaked(uint256 amount, uint256 kHYPEReceived);
    event UnstakeQueued(uint256 hypeAmount, uint256 withdrawalId, uint256 claimableAt);
    event UnstakeClaimed(uint256 withdrawalId, uint256 hypeReceived, address recipient);
    event NAVUpdated(uint256 newNAV);

    // Custom errors
    error KinetiqUnavailable(string reason);
    error NAVBelowMinimum(uint256 currentNAV);
    error WithdrawalNotReady(uint256 withdrawalId);

    // Staking operations
    function stakeHYPE(uint256 amount) external payable returns (uint256 kHYPEReceived);

    // Unstaking operations (same interface for mock and production)
    function queueUnstakeHYPE(uint256 khypeAmount) external returns (uint256 withdrawalId);
    function claimUnstake(uint256 withdrawalId) external returns (uint256 hypeReceived);
    function isUnstakeReady(uint256 withdrawalId) external view returns (bool ready, uint256 hypeAmount);
    function getWithdrawalDelay() external view returns (uint256 delaySeconds);

    // NAV management
    function getExchangeRate() external view returns (uint256);
    function getKHYPEBalance() external view returns (uint256);
    function getKHypeAddress() external view returns (address);

    // Configuration
    function getMinStakingAmount() external view returns (uint256);
    function setMinStakingAmount(uint256 _amount) external;
    function getUnstakeFeeRate() external view returns (uint256);
    function getYieldManager() external view returns (address);
}

// External Kinetiq interfaces
interface IKinetiqStakingManager {
    function stake(uint256 amount) external returns (uint256 shares);
    function queueWithdrawal(uint256 shares) external returns (uint256 withdrawalId);
    function confirmWithdrawal(uint256 withdrawalId) external;
}

interface IKinetiqStakingAccountant {
    function getExchangeRate() external view returns (uint256);
}

interface IKHYPE {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
