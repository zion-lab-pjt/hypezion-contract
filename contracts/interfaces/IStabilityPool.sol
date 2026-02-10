// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./IHypeZionExchange.sol";

interface IStabilityPool is IERC4626 {
    // Events
    event ProtocolIntervention(uint256 zusdConverted, uint256 zhypeReceived);
    event YieldCompounded(uint256 yieldAmount, uint256 newNAV);
    event InterventionStateChanged(bool active);

    // Custom errors
    error InterventionActive();
    error InsufficientPoolBalance(uint256 requested, uint256 available);
    error InvalidCaller(address caller);
    error MixedAssetQuoteFailure();
    error InsufficientShares(uint256 requested, uint256 available);
    error MustUseMixedWithdrawal();
    error InvalidReceiver();

    // Protocol-specific functions
    function protocolIntervention(uint256 amountToConvert, uint256 zhypeReceived) external payable;
    function exitRecoveryMode(uint256 zhypeBurned, uint256 zusdMinted) external;
    function compoundYield(uint256 yieldAmount) external;

    // View functions
    function getNAV() external view returns (uint256);
    function getSharePrice() external view returns (uint256);
    function isInterventionActive() external view returns (bool);
    function poolBalance() external view returns (uint256);
    function totalXHYPE() external view returns (uint256);
    function hzhypeInPool() external view returns (uint256);
    function revertIntervention() external;

    // Unstake fee functions
    function getUnstakeFee() external view returns (uint256 feeBps);
    function unstakeFeeHealthy() external view returns (uint256);
    function unstakeFeeCautious() external view returns (uint256);
    function unstakeFeeCritical() external view returns (uint256);
    function collectUnstakeFees(address recipient) external;
    function accumulatedUnstakeFees() external view returns (uint256);
    function accumulatedUnstakeFeesXHYPE() external view returns (uint256);

    // Recovery mode support
    function isInRecoveryMode() external view returns (bool);
    function previewMixedRedeem(uint256 shares)
        external
        view
        returns (
            uint256 stablecoinAmount,
            uint256 levercoinAmount,
            uint256 totalValue
        );
    function mixedWithdraw(
        uint256 shares,
        address receiver
    ) external returns (
        uint256 stablecoinAmount,
        uint256 levercoinAmount,
        uint256 totalValue
    );
}
