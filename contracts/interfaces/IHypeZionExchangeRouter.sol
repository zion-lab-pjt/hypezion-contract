// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IHypeZionExchangeRouter
 * @notice Interface for the Router as an internal distribution layer
 * @dev Called by Exchange to distribute HYPE across secondary yield sources.
 *      All state-changing functions are gated by EXCHANGE_ROLE.
 */
interface IHypeZionExchangeRouter {
    // ==================== EXCHANGE-ONLY DISTRIBUTION FUNCTIONS ====================

    /**
     * @notice Distribute HYPE across all yield sources (primary Kinetiq/DEX + secondary adapters)
     * @dev Called by Exchange with the FULL HYPE amount during mint.
     *      Router handles: primary staking → transfers kHYPE to Exchange, secondary deposits to adapters.
     * @param swapData KyberSwap swap data (empty = Kinetiq staking, non-empty = DEX swap)
     * @return kHYPEReceived kHYPE transferred to Exchange for vault deposit
     * @return secondaryDeposited HYPE deposited to secondary adapters (for Exchange accounting)
     */
    function distributeDeposit(bytes calldata swapData) external payable returns (uint256 kHYPEReceived, uint256 secondaryDeposited);

    /**
     * @notice Swap kHYPE → HYPE via DEX and withdraw from secondary sources (for swapRedeem)
     * @dev Exchange transfers kHYPE to Router, Router swaps + withdraws, forwards total HYPE to Exchange.
     * @param netKHYPE Amount of kHYPE to swap (already transferred to Router by Exchange)
     * @param swapData KyberSwap encoded swap data for primary kHYPE → HYPE swap
     * @param secondaryPortion HYPE to withdraw from secondary sources
     * @param secondarySwapData KyberSwap encoded swap data for secondary sources needing DEX swap
     *        (e.g., stHYPE → HYPE for StHYPEStakingAdapter). Empty bytes if not needed.
     * @param minHypeOut Minimum total HYPE out (slippage protection)
     * @return hypeReceived Total HYPE forwarded to Exchange
     */
    function swapKHYPEForHYPE(
        uint256 netKHYPE,
        bytes calldata swapData,
        uint256 secondaryPortion,
        bytes calldata secondarySwapData,
        uint256 minHypeOut
    ) external returns (uint256 hypeReceived);

    /**
     * @notice Instantly withdraw HYPE from secondary sources only (without DEX swap)
     * @param hypeAmount Amount of HYPE to withdraw across secondary sources
     * @return hypeReceived Actual HYPE received and forwarded to Exchange (msg.sender)
     */
    function withdrawFromSecondary(uint256 hypeAmount) external returns (uint256 hypeReceived);

    /**
     * @notice Queue withdrawals from secondary sources (for queued redeem)
     * @param hypeAmount Amount of HYPE to queue across secondary sources
     * @return ticketId Secondary ticket ID to use when calling claimSecondaryWithdrawals
     */
    function queueSecondaryWithdrawals(uint256 hypeAmount) external returns (uint256 ticketId);

    /**
     * @notice Claim queued withdrawals from secondary sources
     * @param ticketId Ticket ID returned by queueSecondaryWithdrawals
     * @return hypeReceived Total HYPE received and forwarded to Exchange (msg.sender)
     */
    function claimSecondaryWithdrawals(uint256 ticketId) external returns (uint256 hypeReceived);

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get total reserve value held in secondary sources only (excludes Exchange)
     * @return Total secondary reserve in HYPE
     */
    function getTotalSecondaryReserveInHYPE() external view returns (uint256);

    /**
     * @notice Get effective weights after redistributing disabled sources
     * @return effectivePrimary Effective weight for primary source (Exchange/Kinetiq)
     * @return effectiveSecondary Effective weights for each secondary source
     */
    function getEffectiveWeights() external view returns (
        uint256 effectivePrimary,
        uint256[] memory effectiveSecondary
    );

    /**
     * @notice Get total reserve value across all sources (primary + secondary)
     */
    function getTotalReserveInHYPE() external view returns (uint256);

    /**
     * @notice Check whether a secondary ticket is fully ready to claim
     * @param ticketId Ticket ID returned by queueSecondaryWithdrawals
     * @return ready True if all queued withdrawals in this ticket are claimable
     */
    function isSecondaryTicketReady(uint256 ticketId) external view returns (bool ready);

    /// @notice Check if a secondary ticket is fully claimed (all sources resolved)
    function isSecondaryTicketFullyClaimed(uint256 ticketId) external view returns (bool);

    // ==================== KINETIQ PROXY (saves Exchange from importing IKinetiqIntegration) ====================

    /// @notice kHYPE/HYPE exchange rate from Kinetiq
    function getExchangeRate() external view returns (uint256);

    /// @notice kHYPE token address from Kinetiq
    function getKHypeAddress() external view returns (address);

    /// @notice Kinetiq withdrawal delay (for FE display)
    function getWithdrawalDelay() external view returns (uint256);

    /// @notice YieldManager address from Kinetiq
    function getYieldManager() external view returns (address);

    /**
     * @notice Queue a primary (Kinetiq) withdrawal — Exchange transfers kHYPE to Router first
     * @param netKHYPE Amount of kHYPE to queue (already transferred to Router)
     * @return kinetiqTicket Kinetiq withdrawal ID for later claim
     */
    function queuePrimaryWithdrawal(uint256 netKHYPE) external returns (uint256 kinetiqTicket);

    /**
     * @notice Check if a primary withdrawal is ready to claim
     * @param kinetiqTicket ID returned by queuePrimaryWithdrawal
     * @return ready True if claimable
     * @return expectedHype Expected HYPE amount
     */
    function isPrimaryWithdrawalReady(uint256 kinetiqTicket) external view returns (bool ready, uint256 expectedHype);

    /**
     * @notice Claim a primary (Kinetiq) withdrawal and forward HYPE to Exchange
     * @param kinetiqTicket ID returned by queuePrimaryWithdrawal
     * @return hypeReceived HYPE forwarded to Exchange (msg.sender)
     */
    function claimPrimaryWithdrawal(uint256 kinetiqTicket) external returns (uint256 hypeReceived);

    /**
     * @notice Harvest yield from all secondary sources via full-exit + re-deposit pattern.
     * @dev Callable only by the KinetiqYieldManager (checked via kinetiq.getYieldManager()).
     *      For each enabled source: exits the full LP position, pockets the yield HYPE,
     *      then re-deposits the original cost basis back into the adapter so future yield
     *      calculations start from zero.
     *      Harvested HYPE is forwarded to the caller (YieldManager adds it to pendingHarvestedHype).
     * @param minYield Minimum total HYPE required — reverts with InsufficientYield if not met
     * @return totalYield Total HYPE forwarded to the YieldManager
     */
    function harvestSecondaryYield(uint256 minYield) external returns (uint256 totalYield);

    /**
     * @notice Get source count
     */
    function getSourceCount() external view returns (uint256);

    /**
     * @notice Get source info by index
     */
    function getSource(uint256 index) external view returns (
        address adapter, uint256 weight, bool enabled, string memory name
    );
}
