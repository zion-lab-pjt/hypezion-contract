// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IYieldSourceAdapter
 * @notice Standard interface for yield source adapters in the multi-source system
 * @dev Each yield source (Kinetiq, Valantis pool, future sources) implements this interface.
 *      The Router interacts with all sources uniformly through this interface.
 *
 * Lifecycle:
 *   deposit()         → Deposit HYPE into the yield source
 *   instantWithdraw() → Withdraw HYPE immediately (may incur fees)
 *   queueWithdraw()   → Queue a withdrawal (no instant fee, but delayed)
 *   claimWithdraw()   → Claim a previously queued withdrawal
 *
 * Health:
 *   getReserveInHYPE()  → Current value of our position in HYPE terms
 *   isOperational()     → Whether the source can accept deposits/withdrawals
 *   supportsInstantWithdraw() → Whether instant withdrawal is available
 */
interface IYieldSourceAdapter {
    // ==================== DEPOSIT ====================

    /**
     * @notice Deposit HYPE into this yield source
     * @return deposited Actual HYPE value deposited (may differ from msg.value due to fees)
     */
    function deposit() external payable returns (uint256 deposited);

    // ==================== WITHDRAWAL ====================

    /**
     * @notice Instantly withdraw HYPE from this source
     * @param hypeAmount HYPE value to withdraw
     * @return hypeReceived Actual HYPE received (may be less due to fees/slippage)
     */
    function instantWithdraw(uint256 hypeAmount) external returns (uint256 hypeReceived);

    /**
     * @notice Queue a withdrawal (delayed, typically lower fees)
     * @param hypeAmount HYPE value to withdraw
     * @return ticketId Unique ID to claim this withdrawal later
     */
    function queueWithdraw(uint256 hypeAmount) external returns (uint256 ticketId);

    /**
     * @notice Claim a previously queued withdrawal
     * @param ticketId ID returned by queueWithdraw
     * @return hypeReceived Actual HYPE received
     */
    function claimWithdraw(uint256 ticketId) external returns (uint256 hypeReceived);

    // ==================== VIEW ====================

    /**
     * @notice Get the current value of our position in HYPE terms
     * @return reserveInHYPE Current reserve value
     */
    function getReserveInHYPE() external view returns (uint256 reserveInHYPE);

    /**
     * @notice Check if this source is operational (can deposit/withdraw)
     * @return operational True if the source is functioning normally
     */
    function isOperational() external view returns (bool operational);

    /**
     * @notice Whether this source supports instant withdrawals
     * @return supported True if instantWithdraw() is available
     */
    function supportsInstantWithdraw() external view returns (bool supported);

    /**
     * @notice Get the total amount deposited (cost basis) for yield tracking
     * @return totalDeposited Total HYPE ever deposited minus withdrawn
     */
    function getTotalDeposited() external view returns (uint256 totalDeposited);

    /**
     * @notice Check if a queued withdrawal is ready to claim
     * @param ticketId ID returned by queueWithdraw
     * @return ready True if claimWithdraw can be called
     */
    function isWithdrawReady(uint256 ticketId) external view returns (bool ready);
}
