// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYieldSourceAdapter.sol";
import "../interfaces/ISwapWithdrawable.sol";
import "../interfaces/IOverseerV1.sol";

/**
 * @title StHYPEStakingAdapter
 * @notice Adapter for direct stHYPE staking via Valantis OverseerV1
 * @dev Implements IYieldSourceAdapter + ISwapWithdrawable for the Router's source registry.
 *      stHYPE is a rebasing token: 1 stHYPE = 1 HYPE always, balance increases over time.
 *
 * Deposit:  HYPE → Overseer.mint() → stHYPE (no WHYPE wrapping needed)
 * Withdraw: stHYPE → KyberSwap DEX → HYPE (primary path via instantWithdrawViaSwap)
 *           stHYPE → Overseer.burnAndRedeemIfPossible() → HYPE (fallback via instantWithdraw)
 * Reserve:  stHYPE.balanceOf(this) = HYPE value (1:1 rebasing)
 * Yield:    stHYPE balance grows via rebasing → reserve > deposited = yield
 */
contract StHYPEStakingAdapter is
    IYieldSourceAdapter,
    ISwapWithdrawable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ==================== ROLES ====================
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ==================== STATE ====================

    address public overseer;          // Valantis OverseerV1
    address public stHYPE;            // stHYPE token
    uint256 public communityCode;     // Community code for mint tracking

    // Tracking
    uint256 public totalDeposited;    // Cost basis in HYPE
    uint256 public nextTicketId;

    struct WithdrawalTicket {
        uint256 burnId;           // OverseerV1 burn ID
        uint256 expectedHype;     // HYPE amount expected
        bool claimed;
    }
    mapping(uint256 => WithdrawalTicket) public tickets;

    // ==================== NEW STATE (V2 — uses gap slots) ====================
    address public kyberswapRouter;   // KyberSwap MetaAggregationRouterV2

    // ==================== STORAGE GAP ====================
    uint256[39] private __gap;        // reduced from 40 → 39 (1 slot used by kyberswapRouter)

    // ==================== EVENTS ====================
    event Deposited(uint256 amount);
    event InstantWithdrawn(uint256 requested, uint256 received);
    event SwapWithdrawn(uint256 requested, uint256 received);
    event WithdrawalQueued(uint256 ticketId, uint256 burnId, uint256 amount);
    event WithdrawalClaimed(uint256 ticketId, uint256 received);

    // ==================== ERRORS ====================
    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error TicketNotReady(uint256 ticketId);
    error TicketAlreadyClaimed(uint256 ticketId);
    error InvalidTicket(uint256 ticketId);
    error HYPETransferFailed();
    error SwapFailed();
    error KyberswapRouterNotSet();

    // ==================== INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _overseer,
        address _stHYPE,
        uint256 _communityCode,
        address _admin
    ) external initializer {
        require(_overseer != address(0) && _stHYPE != address(0) && _admin != address(0), "Zero address");

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        overseer = _overseer;
        stHYPE = _stHYPE;
        communityCode = _communityCode;
        nextTicketId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    // ==================== DEPOSIT ====================

    /// @inheritdoc IYieldSourceAdapter
    function deposit() external payable override onlyRole(ROUTER_ROLE) whenNotPaused returns (uint256 deposited) {
        require(msg.value > 0, "Zero deposit");

        uint256 balBefore = IERC20(stHYPE).balanceOf(address(this));
        IOverseerV1(overseer).mint{value: msg.value}(address(this));
        uint256 balAfter = IERC20(stHYPE).balanceOf(address(this));

        deposited = balAfter - balBefore;
        totalDeposited += deposited;

        emit Deposited(deposited);
    }

    // ==================== WITHDRAWAL ====================

    /// @inheritdoc IYieldSourceAdapter
    /// @dev Fallback path via Overseer burn. May return 0 if no instant liquidity.
    ///      Primary withdrawal path is instantWithdrawViaSwap (KyberSwap DEX).
    function instantWithdraw(uint256 hypeAmount)
        external
        override
        onlyRole(ROUTER_ROLE)
        whenNotPaused
        returns (uint256 hypeReceived)
    {
        uint256 stBal = IERC20(stHYPE).balanceOf(address(this));
        if (stBal < hypeAmount) hypeAmount = stBal;
        if (hypeAmount == 0) return 0;

        // Approve overseer to spend stHYPE
        IERC20(stHYPE).approve(overseer, hypeAmount);

        // Burn stHYPE — Overseer returns whatever is instantly available
        uint256 hypeBefore = address(this).balance;
        IOverseerV1(overseer).burnAndRedeemIfPossible(address(this), hypeAmount, "");
        hypeReceived = address(this).balance - hypeBefore;

        _reduceDeposited(hypeAmount);

        // Forward HYPE to caller (Router)
        if (hypeReceived > 0) {
            (bool ok,) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit InstantWithdrawn(hypeAmount, hypeReceived);
    }

    /// @inheritdoc ISwapWithdrawable
    /// @dev Primary withdrawal path: swap stHYPE → HYPE via KyberSwap DEX.
    ///      Swap data must be generated off-chain with sender=this, recipient=this.
    function instantWithdrawViaSwap(uint256 hypeAmount, bytes calldata swapData)
        external
        override
        onlyRole(ROUTER_ROLE)
        whenNotPaused
        returns (uint256 hypeReceived)
    {
        if (kyberswapRouter == address(0)) revert KyberswapRouterNotSet();

        uint256 stBal = IERC20(stHYPE).balanceOf(address(this));
        if (stBal < hypeAmount) hypeAmount = stBal;
        if (hypeAmount == 0) return 0;

        // Approve KyberSwap router to pull stHYPE
        // Use lazy infinite approval — safe because kyberswapRouter is admin-controlled
        uint256 currentAllowance = IERC20(stHYPE).allowance(address(this), kyberswapRouter);
        if (currentAllowance < hypeAmount) {
            IERC20(stHYPE).forceApprove(kyberswapRouter, type(uint256).max);
        }

        // Execute swap: stHYPE → HYPE via KyberSwap
        uint256 hypeBefore = address(this).balance;
        (bool success, bytes memory result) = kyberswapRouter.call(swapData);
        if (!success) {
            // Bubble up revert reason if available
            if (result.length > 0) {
                assembly {
                    let size := mload(result)
                    revert(add(32, result), size)
                }
            }
            revert SwapFailed();
        }
        hypeReceived = address(this).balance - hypeBefore;

        _reduceDeposited(hypeAmount);

        // Forward HYPE to caller (Router)
        if (hypeReceived > 0) {
            (bool ok,) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit SwapWithdrawn(hypeAmount, hypeReceived);
    }

    /// @inheritdoc IYieldSourceAdapter
    function queueWithdraw(uint256 hypeAmount)
        external
        override
        onlyRole(ROUTER_ROLE)
        whenNotPaused
        returns (uint256 ticketId)
    {
        uint256 stBal = IERC20(stHYPE).balanceOf(address(this));
        if (stBal < hypeAmount) revert InsufficientBalance(stBal, hypeAmount);

        // Approve overseer to spend stHYPE
        IERC20(stHYPE).approve(overseer, hypeAmount);

        uint256 hypeBefore = address(this).balance;
        uint256 burnId = IOverseerV1(overseer).burnAndRedeemIfPossible(address(this), hypeAmount, "");
        uint256 instantReceived = address(this).balance - hypeBefore;

        // Do NOT forward instant HYPE to Router during queue.
        // Keep it in adapter — will be forwarded during claimWithdraw.
        // This ensures Router's claimSecondaryWithdrawals returns the full amount.

        ticketId = nextTicketId++;
        tickets[ticketId] = WithdrawalTicket({
            burnId: burnId,
            expectedHype: hypeAmount,
            claimed: false
        });

        _reduceDeposited(hypeAmount);

        emit WithdrawalQueued(ticketId, burnId, hypeAmount);
    }

    /// @inheritdoc IYieldSourceAdapter
    function claimWithdraw(uint256 ticketId)
        external
        override
        onlyRole(ROUTER_ROLE)
        returns (uint256 hypeReceived)
    {
        WithdrawalTicket storage ticket = tickets[ticketId];
        if (ticket.expectedHype == 0 && ticket.burnId == 0) revert InvalidTicket(ticketId);
        if (ticket.claimed) revert TicketAlreadyClaimed(ticketId);

        uint256 hypeBefore = address(this).balance;

        // Try claiming remaining from Overseer (may have been partially or fully instant-redeemed)
        try IOverseerV1(overseer).redeem(ticket.burnId) {} catch {
            // Already fully redeemed during queue — instant HYPE sitting in adapter balance
        }

        // Forward all HYPE received (instant from queue + any from redeem) to Router
        // expectedHype was set to full amount during queue; adapter holds instant portion
        hypeReceived = address(this).balance - hypeBefore;

        // If Overseer didn't return anything new, forward the instant portion held since queue
        if (hypeReceived == 0 && ticket.expectedHype > 0) {
            // Instant HYPE held in adapter since queueWithdraw
            hypeReceived = ticket.expectedHype <= address(this).balance ? ticket.expectedHype : address(this).balance;
        }

        ticket.claimed = true;

        if (hypeReceived > 0) {
            (bool ok,) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit WithdrawalClaimed(ticketId, hypeReceived);
    }

    // ==================== VIEW ====================

    /// @inheritdoc IYieldSourceAdapter
    function getReserveInHYPE() external view override returns (uint256) {
        // stHYPE is rebasing: 1 stHYPE = 1 HYPE always
        return IERC20(stHYPE).balanceOf(address(this));
    }

    /// @inheritdoc IYieldSourceAdapter
    function getTotalDeposited() external view override returns (uint256) {
        return totalDeposited;
    }

    /// @inheritdoc IYieldSourceAdapter
    function isOperational() external view override returns (bool) {
        return overseer != address(0) && stHYPE != address(0) && !paused();
    }

    /// @inheritdoc IYieldSourceAdapter
    function supportsInstantWithdraw() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IYieldSourceAdapter
    function isWithdrawReady(uint256 ticketId) external view override returns (bool) {
        WithdrawalTicket storage ticket = tickets[ticketId];
        if (ticket.claimed) return false;
        if (ticket.expectedHype == 0) return true;
        // Ready if: adapter holds enough HYPE (instant from queue) OR Overseer has redeemed
        if (address(this).balance >= ticket.expectedHype) return true;
        try IOverseerV1(overseer).redeemable(ticket.burnId) returns (bool redeemable) {
            return redeemable;
        } catch {
            return address(this).balance > 0; // fallback: ready if any HYPE available
        }
    }

    // ==================== ADMIN ====================

    function setCommunityCode(uint256 _code) external onlyRole(ADMIN_ROLE) {
        communityCode = _code;
    }

    function setOverseer(address _overseer) external onlyRole(ADMIN_ROLE) {
        require(_overseer != address(0), "Zero address");
        overseer = _overseer;
    }

    function setStHYPE(address _stHYPE) external onlyRole(ADMIN_ROLE) {
        require(_stHYPE != address(0), "Zero address");
        stHYPE = _stHYPE;
    }

    function setKyberswapRouter(address _kyberswapRouter) external onlyRole(ADMIN_ROLE) {
        require(_kyberswapRouter != address(0), "Zero address");
        kyberswapRouter = _kyberswapRouter;
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

    // Accept native HYPE from Overseer/KyberSwap during withdrawal
    receive() external payable {}
}
