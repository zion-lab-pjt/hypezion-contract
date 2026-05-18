// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IYieldSourceAdapter.sol";

interface IKinetiqStaking {
    function stake(uint256 amount) external payable returns (uint256 shares);
    function queueWithdrawal(uint256 shares) external returns (uint256 withdrawalId);
    function confirmWithdrawal(uint256 withdrawalId) external;
}

interface IKinetiqAccountant {
    function getExchangeRate() external view returns (uint256);
}

contract KHYPEAdapter is
    IYieldSourceAdapter,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public kinetiqStakingManager;
    address public kinetiqAccountant;
    address public kHYPE;

    uint256 public totalDeposited;
    uint256 public nextTicketId;

    struct WithdrawalTicket {
        uint256 kinetiqWithdrawalId;
        uint256 kHYPEAmount;
        uint256 expectedHype;
        bool claimed;
    }
    mapping(uint256 => WithdrawalTicket) public tickets;

    uint256[40] private __gap;

    event Deposited(uint256 hypeAmount, uint256 kHYPEReceived);
    event WithdrawalQueued(uint256 ticketId, uint256 kinetiqId, uint256 kHYPEAmount);
    event WithdrawalClaimed(uint256 ticketId, uint256 hypeReceived);

    error HYPETransferFailed();
    error InsufficientKHYPE(uint256 available, uint256 requested);
    error TicketNotFound(uint256 ticketId);
    error TicketAlreadyClaimed(uint256 ticketId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _kinetiqStakingManager,
        address _kinetiqAccountant,
        address _kHYPE,
        address _admin
    ) external initializer {
        require(
            _kinetiqStakingManager != address(0) &&
            _kinetiqAccountant != address(0) &&
            _kHYPE != address(0) &&
            _admin != address(0),
            "Zero address"
        );

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        kinetiqStakingManager = _kinetiqStakingManager;
        kinetiqAccountant = _kinetiqAccountant;
        kHYPE = _kHYPE;
        nextTicketId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    // ==================== DEPOSIT ====================

    function deposit() external payable override onlyRole(VAULT_ROLE) whenNotPaused returns (uint256 deposited) {
        require(msg.value > 0, "Zero deposit");

        uint256 kHYPEBefore = IERC20(kHYPE).balanceOf(address(this));
        IKinetiqStaking(kinetiqStakingManager).stake{value: msg.value}(msg.value);
        uint256 kHYPEAfter = IERC20(kHYPE).balanceOf(address(this));

        uint256 kHYPEReceived = kHYPEAfter - kHYPEBefore;
        totalDeposited += msg.value;

        deposited = msg.value;
        emit Deposited(msg.value, kHYPEReceived);
    }

    // ==================== WITHDRAWAL ====================

    function instantWithdraw(uint256)
        external
        view
        override
        onlyRole(VAULT_ROLE)
        whenNotPaused
        returns (uint256)
    {
        return 0;
    }

    function queueWithdraw(uint256 hypeAmount)
        external
        override
        onlyRole(VAULT_ROLE)
        whenNotPaused
        returns (uint256 ticketId)
    {
        uint256 exchangeRate = IKinetiqAccountant(kinetiqAccountant).getExchangeRate();
        // exchangeRate = HYPE per kHYPE (scaled 1e18)
        uint256 kHYPENeeded = (hypeAmount * 1e18) / exchangeRate;

        uint256 kHYPEBalance = IERC20(kHYPE).balanceOf(address(this));
        if (kHYPEBalance < kHYPENeeded) revert InsufficientKHYPE(kHYPEBalance, kHYPENeeded);

        IERC20(kHYPE).forceApprove(kinetiqStakingManager, kHYPENeeded);
        uint256 kinetiqId = IKinetiqStaking(kinetiqStakingManager).queueWithdrawal(kHYPENeeded);

        ticketId = nextTicketId++;
        tickets[ticketId] = WithdrawalTicket({
            kinetiqWithdrawalId: kinetiqId,
            kHYPEAmount: kHYPENeeded,
            expectedHype: hypeAmount,
            claimed: false
        });

        _reduceDeposited(hypeAmount);
        emit WithdrawalQueued(ticketId, kinetiqId, kHYPENeeded);
    }

    function claimWithdraw(uint256 ticketId)
        external
        override
        onlyRole(VAULT_ROLE)
        returns (uint256 hypeReceived)
    {
        WithdrawalTicket storage ticket = tickets[ticketId];
        if (ticket.expectedHype == 0) revert TicketNotFound(ticketId);
        if (ticket.claimed) revert TicketAlreadyClaimed(ticketId);

        uint256 hypeBefore = address(this).balance;
        IKinetiqStaking(kinetiqStakingManager).confirmWithdrawal(ticket.kinetiqWithdrawalId);
        hypeReceived = address(this).balance - hypeBefore;

        ticket.claimed = true;

        if (hypeReceived > 0) {
            (bool ok,) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit WithdrawalClaimed(ticketId, hypeReceived);
    }

    // ==================== VIEW ====================

    function getReserveInHYPE() external view override returns (uint256) {
        uint256 kHYPEBalance = IERC20(kHYPE).balanceOf(address(this));
        uint256 exchangeRate = IKinetiqAccountant(kinetiqAccountant).getExchangeRate();
        return (kHYPEBalance * exchangeRate) / 1e18;
    }

    function getTotalDeposited() external view override returns (uint256) {
        return totalDeposited;
    }

    function isOperational() external view override returns (bool) {
        return kinetiqStakingManager != address(0) && !paused();
    }

    function supportsInstantWithdraw() external pure override returns (bool) {
        return false;
    }

    function isWithdrawReady(uint256 ticketId) external view override returns (bool) {
        WithdrawalTicket storage ticket = tickets[ticketId];
        if (ticket.claimed || ticket.expectedHype == 0) return false;
        // Kinetiq withdrawal delay is 7 days — checked externally
        return true;
    }

    // ==================== ADMIN ====================

    function setKinetiqStakingManager(address _manager) external onlyRole(ADMIN_ROLE) {
        require(_manager != address(0), "Zero address");
        kinetiqStakingManager = _manager;
    }

    function setKinetiqAccountant(address _accountant) external onlyRole(ADMIN_ROLE) {
        require(_accountant != address(0), "Zero address");
        kinetiqAccountant = _accountant;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ==================== INTERNAL ====================

    function _reduceDeposited(uint256 amount) internal {
        totalDeposited = amount > totalDeposited ? 0 : totalDeposited - amount;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    receive() external payable {}
}
