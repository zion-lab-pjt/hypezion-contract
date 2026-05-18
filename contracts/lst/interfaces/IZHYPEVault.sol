// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IZHYPEVault {
    // ==================== EVENTS ====================

    event Staked(address indexed user, uint256 hypeAmount, uint256 zHYPEMinted);
    event WithdrawalRequested(address indexed user, uint256 requestId, uint256 zHYPEAmount, uint256 hypeAmount);
    event WithdrawalClaimed(address indexed user, uint256 requestId, uint256 hypeReceived);
    event Rebalanced(uint256 timestamp);
    event AdapterAdded(address indexed adapter, uint256 targetWeight);
    event AdapterRemoved(address indexed adapter);
    event TargetWeightsUpdated(address[] adapters, uint256[] weights);
    event BufferReplenished(uint256 amount);

    // ==================== ERRORS ====================

    error ZeroDeposit();
    error ZeroAmount();
    error InsufficientZHYPE(uint256 available, uint256 requested);
    error AdapterAlreadyExists(address adapter);
    error AdapterNotFound(address adapter);
    error WeightsSumInvalid(uint256 sum);
    error NoAdaptersConfigured();
    error VaultPaused();

    // ==================== USER FUNCTIONS ====================

    function stake() external payable returns (uint256 zHYPEMinted);

    function requestWithdrawal(uint256 zHYPEAmount) external returns (uint256 requestId);

    function claimWithdrawal(uint256 requestId) external returns (uint256 hypeReceived);

    // ==================== VIEW FUNCTIONS ====================

    function totalAssetsInHYPE() external view returns (uint256);

    function convertToShares(uint256 hypeAmount) external view returns (uint256 zHYPEAmount);

    function convertToAssets(uint256 zHYPEAmount) external view returns (uint256 hypeAmount);

    function getExchangeRate() external view returns (uint256);

    function getAdapters() external view returns (address[] memory);

    function getAdapterWeight(address adapter) external view returns (uint256);

    function getBufferBalance() external view returns (uint256);
}
