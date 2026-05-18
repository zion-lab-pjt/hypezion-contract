// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IZHYPEWithdrawalQueue {
    // ==================== STRUCTS ====================

    struct WithdrawalRequest {
        address owner;
        uint256 zHYPEAmount;
        uint256 hypeAmount;
        uint256 requestTime;
        uint256 claimableTime;
        bool claimed;
        AdapterTicket[] adapterTickets;
    }

    struct AdapterTicket {
        address adapter;
        uint256 ticketId;
        uint256 hypeAmount;
        bool claimed;
    }

    // ==================== EVENTS ====================

    event WithdrawalQueued(
        uint256 indexed requestId,
        address indexed owner,
        uint256 zHYPEAmount,
        uint256 hypeAmount
    );
    event WithdrawalClaimed(uint256 indexed requestId, address indexed owner, uint256 hypeReceived);
    event InstantWithdrawal(address indexed owner, uint256 hypeAmount);

    // ==================== ERRORS ====================

    error RequestNotFound(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error NotRequestOwner(uint256 requestId, address caller);
    error WithdrawalNotReady(uint256 requestId);
    error ZeroAmount();

    // ==================== FUNCTIONS ====================

    function createRequest(
        address owner,
        uint256 zHYPEAmount,
        uint256 hypeAmount,
        AdapterTicket[] calldata tickets
    ) external returns (uint256 requestId);

    function markClaimed(uint256 requestId) external;

    function getRequest(uint256 requestId) external view returns (
        address owner,
        uint256 zHYPEAmount,
        uint256 hypeAmount,
        uint256 requestTime,
        uint256 claimableTime,
        bool claimed
    );

    function isClaimable(uint256 requestId) external view returns (bool);

    function getUserRequests(address user) external view returns (uint256[] memory);

    function getAdapterTickets(uint256 requestId) external view returns (AdapterTicket[] memory);
}
