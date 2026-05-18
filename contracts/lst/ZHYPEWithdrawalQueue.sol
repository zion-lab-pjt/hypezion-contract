// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IZHYPEWithdrawalQueue.sol";

contract ZHYPEWithdrawalQueue is
    IZHYPEWithdrawalQueue,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    uint256 public nextRequestId;
    uint256 public withdrawalDelay;

    struct StoredRequest {
        address owner;
        uint256 zHYPEAmount;
        uint256 hypeAmount;
        uint256 requestTime;
        uint256 claimableTime;
        bool claimed;
    }

    struct StoredTicket {
        address adapter;
        uint256 ticketId;
        uint256 hypeAmount;
        bool claimed;
    }

    mapping(uint256 => StoredRequest) internal _requests;
    mapping(uint256 => StoredTicket[]) internal _tickets;
    mapping(address => uint256[]) internal _userRequests;

    uint256[40] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, uint256 _withdrawalDelay) external initializer {
        require(admin != address(0), "Zero address");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        nextRequestId = 1;
        withdrawalDelay = _withdrawalDelay;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createRequest(
        address owner,
        uint256 zHYPEAmount,
        uint256 hypeAmount,
        AdapterTicket[] calldata tickets
    ) external onlyRole(VAULT_ROLE) returns (uint256 requestId) {
        if (hypeAmount == 0) revert ZeroAmount();

        requestId = nextRequestId++;

        _requests[requestId] = StoredRequest({
            owner: owner,
            zHYPEAmount: zHYPEAmount,
            hypeAmount: hypeAmount,
            requestTime: block.timestamp,
            claimableTime: block.timestamp + withdrawalDelay,
            claimed: false
        });

        for (uint256 i = 0; i < tickets.length; i++) {
            _tickets[requestId].push(StoredTicket({
                adapter: tickets[i].adapter,
                ticketId: tickets[i].ticketId,
                hypeAmount: tickets[i].hypeAmount,
                claimed: false
            }));
        }

        _userRequests[owner].push(requestId);

        emit WithdrawalQueued(requestId, owner, zHYPEAmount, hypeAmount);
    }

    function markClaimed(uint256 requestId) external onlyRole(VAULT_ROLE) {
        StoredRequest storage req = _requests[requestId];
        if (req.owner == address(0)) revert RequestNotFound(requestId);
        if (req.claimed) revert RequestAlreadyClaimed(requestId);

        req.claimed = true;
        emit WithdrawalClaimed(requestId, req.owner, req.hypeAmount);
    }

    function markTicketClaimed(uint256 requestId, uint256 ticketIndex) external onlyRole(VAULT_ROLE) {
        _tickets[requestId][ticketIndex].claimed = true;
    }

    // ==================== VIEW ====================

    function getRequest(uint256 requestId) external view returns (
        address owner,
        uint256 zHYPEAmount,
        uint256 hypeAmount,
        uint256 requestTime,
        uint256 claimableTime,
        bool claimed
    ) {
        StoredRequest storage req = _requests[requestId];
        return (req.owner, req.zHYPEAmount, req.hypeAmount, req.requestTime, req.claimableTime, req.claimed);
    }

    function isClaimable(uint256 requestId) external view returns (bool) {
        StoredRequest storage req = _requests[requestId];
        if (req.claimed || req.owner == address(0)) return false;
        if (block.timestamp < req.claimableTime) return false;

        StoredTicket[] storage tix = _tickets[requestId];
        if (tix.length == 0) return true;

        for (uint256 i = 0; i < tix.length; i++) {
            if (!tix[i].claimed) return false;
        }
        return true;
    }

    function getUserRequests(address user) external view returns (uint256[] memory) {
        return _userRequests[user];
    }

    function getAdapterTickets(uint256 requestId) external view returns (AdapterTicket[] memory) {
        StoredTicket[] storage stored = _tickets[requestId];
        AdapterTicket[] memory result = new AdapterTicket[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            result[i] = AdapterTicket({
                adapter: stored[i].adapter,
                ticketId: stored[i].ticketId,
                hypeAmount: stored[i].hypeAmount,
                claimed: stored[i].claimed
            });
        }
        return result;
    }

    event WithdrawalDelayUpdated(uint256 oldDelay, uint256 newDelay);

    function setWithdrawalDelay(uint256 _delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = withdrawalDelay;
        withdrawalDelay = _delay;
        emit WithdrawalDelayUpdated(old, _delay);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
