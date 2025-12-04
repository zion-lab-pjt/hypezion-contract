// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../interfaces/IKinetiqIntegration.sol";

/**
 * @title HypeZionWithdrawalManagerLibrary
 * @notice Library for managing asynchronous withdrawals from Kinetiq staking
 * @dev Handles queueing, tracking, and claiming of withdrawals
 *      Status checking delegated to Kinetiq's actual withdrawal state
 */
library HypeZionWithdrawalManagerLibrary {
    // Withdrawal states
    enum WithdrawalState {
        Queued,
        Ready,
        Claimed,
        Cancelled
    }

    // Withdrawal request structure
    struct WithdrawalRequest {
        address requester;
        uint256 tokenAmount;      // Amount of zUSD or zHYPE to burn
        uint256 khypeAmount;      // Amount of kHYPE to unstake
        uint256 expectedHype;     // Expected HYPE to receive
        uint256 queuedAt;
        uint256 readyAt;         // Estimated timestamp when withdrawal will be ready (for FE display). Actual status checked via Kinetiq's isUnstakeReady()
        uint256 claimedAt;
        uint256 kinetiqWithdrawalId; // Kinetiq withdrawal ID
        WithdrawalState state;
        bool isZusd;             // true for zUSD, false for zHYPE
    }

    // Storage structure for withdrawals
    struct WithdrawalStorage {
        mapping(uint256 => WithdrawalRequest) requests;
        mapping(address => uint256[]) userWithdrawals;
        uint256 nextWithdrawalId;

        // Statistics
        uint256 totalQueued;
        uint256 totalReady;
        uint256 totalClaimed;
        uint256 totalCancelled;

        // Configuration
        uint256 minWithdrawalAmount;
        uint256 maxPendingWithdrawals;
        uint256 withdrawalDelay; // DEPRECATED: Not used, kept for storage compatibility. Kinetiq controls the delay
    }

    // Events
    event WithdrawalQueued(
        uint256 indexed requestId,
        address indexed requester,
        uint256 tokenAmount,
        uint256 expectedHype,
        uint256 readyAt,
        bool isZusd
    );

    event WithdrawalReady(uint256 indexed requestId, address indexed requester);

    event WithdrawalClaimed(
        uint256 indexed requestId,
        address indexed requester,
        uint256 hypeAmount,
        uint256 tokenBurned,
        bool isZusd
    );

    event WithdrawalCancelled(uint256 indexed requestId, address indexed requester);

    // Errors
    error WithdrawalTooSmall(uint256 amount, uint256 minimum);
    error TooManyPendingWithdrawals(address user, uint256 pending, uint256 maximum);
    error WithdrawalNotFound(uint256 requestId);
    error WithdrawalNotReady(uint256 requestId, uint256 timeRemaining);
    error WithdrawalAlreadyClaimed(uint256 requestId);
    error UnauthorizedWithdrawal(uint256 requestId, address caller, address owner);
    error InvalidWithdrawalDelay(uint256 delay);
    error InvalidMinAmount(uint256 amount);

    /**
     * @notice Initialize withdrawal storage with default values
     * @param self Storage pointer
     * @param _withdrawalDelay Delay in seconds before withdrawal can be claimed
     */
    function initialize(
        WithdrawalStorage storage self,
        uint256 _withdrawalDelay
    ) internal {
        self.nextWithdrawalId = 1;
        // minWithdrawalAmount removed - validation handled at protocol level
        self.maxPendingWithdrawals = 10;
        self.withdrawalDelay = _withdrawalDelay;
    }

    /**
     * @notice Queue a withdrawal request
     * @param self Storage pointer
     * @param requester Address of the requester
     * @param tokenAmount Amount of zUSD/zHYPE to burn (when claimed)
     * @param khypeAmount Amount of kHYPE to withdraw
     * @param expectedHype Expected HYPE amount to receive
     * @param kinetiqWithdrawalId Withdrawal ID from Kinetiq
     * @param isZusd Whether this is a zUSD redemption (vs zHYPE)
     * @param kinetiq Kinetiq integration contract
     * @return requestId Withdrawal request ID
     */
    function queueWithdrawal(
        WithdrawalStorage storage self,
        address requester,
        uint256 tokenAmount,
        uint256 khypeAmount,
        uint256 expectedHype,
        uint256 kinetiqWithdrawalId,
        bool isZusd,
        IKinetiqIntegration kinetiq
    ) internal returns (uint256 requestId) {
        // Check pending withdrawals limit
        uint256 pendingCount = countPendingWithdrawals(self, requester);
        if (pendingCount >= self.maxPendingWithdrawals) {
            revert TooManyPendingWithdrawals(requester, pendingCount, self.maxPendingWithdrawals);
        }

        // Get withdrawal delay from Kinetiq for FE display
        uint256 withdrawalDelay = kinetiq.getWithdrawalDelay();

        // Create withdrawal request
        requestId = self.nextWithdrawalId++;
        self.requests[requestId] = WithdrawalRequest({
            requester: requester,
            tokenAmount: tokenAmount,
            khypeAmount: khypeAmount,
            expectedHype: expectedHype,
            queuedAt: block.timestamp,
            readyAt: block.timestamp + withdrawalDelay, // For FE display, actual status checked via isUnstakeReady()
            claimedAt: 0,
            kinetiqWithdrawalId: kinetiqWithdrawalId,
            state: WithdrawalState.Queued,
            isZusd: isZusd
        });

        // Track user withdrawals
        self.userWithdrawals[requester].push(requestId);

        // Update stats
        self.totalQueued++;

        emit WithdrawalQueued(
            requestId,
            requester,
            tokenAmount,
            expectedHype,
            block.timestamp + withdrawalDelay, // Estimated readyAt for FE display
            isZusd
        );

        return requestId;
    }

    /**
     * @notice Check and update withdrawal status by querying Kinetiq
     * @param self Storage pointer
     * @param requestId Withdrawal request ID
     * @param kinetiq Kinetiq integration contract
     */
    function checkWithdrawalStatus(
        WithdrawalStorage storage self,
        uint256 requestId,
        IKinetiqIntegration kinetiq
    ) internal {
        WithdrawalRequest storage request = self.requests[requestId];

        if (request.requester == address(0)) {
            revert WithdrawalNotFound(requestId);
        }

        if (request.state != WithdrawalState.Queued) return;

        // Check if withdrawal is ready in Kinetiq
        (bool ready, ) = kinetiq.isUnstakeReady(request.kinetiqWithdrawalId);
        if (ready) {
            request.state = WithdrawalState.Ready;
            self.totalQueued--;
            self.totalReady++;

            emit WithdrawalReady(requestId, request.requester);
        }
    }

    /**
     * @notice Prepare withdrawal for claiming (validate and return details)
     * @param self Storage pointer
     * @param requestId Withdrawal request ID
     * @param caller Address attempting to claim
     * @param kinetiq Kinetiq integration contract
     * @return request The withdrawal request details
     */
    function prepareClaimWithdrawal(
        WithdrawalStorage storage self,
        uint256 requestId,
        address caller,
        IKinetiqIntegration kinetiq
    ) internal returns (WithdrawalRequest storage request) {
        request = self.requests[requestId];

        // Validations
        if (request.requester == address(0)) {
            revert WithdrawalNotFound(requestId);
        }

        if (request.requester != caller) {
            revert UnauthorizedWithdrawal(requestId, caller, request.requester);
        }

        if (request.state == WithdrawalState.Claimed) {
            revert WithdrawalAlreadyClaimed(requestId);
        }

        // Check if withdrawal is ready in Kinetiq
        (bool ready, ) = kinetiq.isUnstakeReady(request.kinetiqWithdrawalId);
        if (request.state != WithdrawalState.Ready && !ready) {
            revert WithdrawalNotReady(requestId, 0); // timeRemaining not available from Kinetiq
        }

        // Update state if it wasn't already marked as ready
        if (request.state == WithdrawalState.Queued && ready) {
            request.state = WithdrawalState.Ready;
            self.totalQueued--;
            self.totalReady++;
        }

        return request;
    }

    /**
     * @notice Mark withdrawal as claimed
     * @param self Storage pointer
     * @param requestId Withdrawal request ID
     * @param actualHypeReceived Actual HYPE amount received
     */
    function markWithdrawalClaimed(
        WithdrawalStorage storage self,
        uint256 requestId,
        uint256 actualHypeReceived
    ) internal {
        WithdrawalRequest storage request = self.requests[requestId];

        // Update request
        request.state = WithdrawalState.Claimed;
        request.claimedAt = block.timestamp;

        // Update stats
        self.totalReady--;
        self.totalClaimed++;

        emit WithdrawalClaimed(
            requestId,
            request.requester,
            actualHypeReceived,
            request.tokenAmount,
            request.isZusd
        );
    }


    /**
     * @notice Cancel a pending withdrawal
     * @param self Storage pointer
     * @param requestId Withdrawal request ID
     * @param caller Address attempting to cancel
     */
    function cancelWithdrawal(
        WithdrawalStorage storage self,
        uint256 requestId,
        address caller
    ) internal {
        WithdrawalRequest storage request = self.requests[requestId];

        // Validations
        if (request.requester == address(0)) {
            revert WithdrawalNotFound(requestId);
        }

        if (request.requester != caller) {
            revert UnauthorizedWithdrawal(requestId, caller, request.requester);
        }

        if (request.state != WithdrawalState.Queued) {
            revert WithdrawalAlreadyClaimed(requestId);
        }

        // Update state
        request.state = WithdrawalState.Cancelled;

        // Update stats
        self.totalQueued--;
        self.totalCancelled++;

        emit WithdrawalCancelled(requestId, caller);
    }

    /**
     * @notice Get user's withdrawal request IDs
     * @param self Storage pointer
     * @param user User address
     * @return requestIds Array of withdrawal request IDs
     */
    function getUserWithdrawals(
        WithdrawalStorage storage self,
        address user
    ) internal view returns (uint256[] memory) {
        return self.userWithdrawals[user];
    }

    /**
     * @notice Check if withdrawal is ready to claim by querying Kinetiq
     * @param self Storage pointer
     * @param requestId Request ID
     * @param kinetiq Kinetiq integration contract
     * @return isReady Whether withdrawal can be claimed
     * @return readyAt Estimated timestamp when withdrawal will be ready (for FE display)
     */
    function isWithdrawalReady(
        WithdrawalStorage storage self,
        uint256 requestId,
        IKinetiqIntegration kinetiq
    ) internal view returns (bool isReady, uint256 readyAt) {
        WithdrawalRequest memory request = self.requests[requestId];

        if (request.requester == address(0)) {
            return (false, 0);
        }

        // If already marked as Ready or Claimed, return true
        if (request.state == WithdrawalState.Ready) {
            return (true, request.readyAt);
        }

        // If queued, check actual Kinetiq status
        if (request.state == WithdrawalState.Queued) {
            (bool ready, ) = kinetiq.isUnstakeReady(request.kinetiqWithdrawalId);
            return (ready, request.readyAt);
        }

        return (false, 0);
    }

    /**
     * @notice Count pending withdrawals for a user
     * @param self Storage pointer
     * @param user User address
     * @return count Number of pending withdrawals
     */
    function countPendingWithdrawals(
        WithdrawalStorage storage self,
        address user
    ) internal view returns (uint256 count) {
        uint256[] memory requests = self.userWithdrawals[user];
        for (uint256 i = 0; i < requests.length; i++) {
            WithdrawalRequest memory request = self.requests[requests[i]];
            if (request.state == WithdrawalState.Queued ||
                request.state == WithdrawalState.Ready) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Set withdrawal delay
     * @param self Storage pointer
     * @param newDelay New delay in seconds
     */
    function setWithdrawalDelay(
        WithdrawalStorage storage self,
        uint256 newDelay
    ) internal {
        if (newDelay == 0 || newDelay > 30 days) {
            revert InvalidWithdrawalDelay(newDelay);
        }
        self.withdrawalDelay = newDelay;
    }

    /**
     * @notice Set minimum withdrawal amount
     * @param self Storage pointer
     * @param newMin New minimum amount
     */
    function setMinWithdrawalAmount(
        WithdrawalStorage storage self,
        uint256 newMin
    ) internal {
        if (newMin == 0) {
            revert InvalidMinAmount(newMin);
        }
        self.minWithdrawalAmount = newMin;
    }
}