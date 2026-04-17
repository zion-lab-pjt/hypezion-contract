// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYieldSourceAdapter.sol";
import "../interfaces/IValantis.sol";

/**
 * @title ValantisPoolAdapter
 * @notice Adapter for a single Valantis STEX AMM pool (kHYPE/WHYPE or stHYPE/WHYPE)
 * @dev Implements IYieldSourceAdapter for plugging into the Router's source registry.
 *      Each Valantis pool gets its own adapter instance.
 *
 * Deposit: HYPE → wrap WHYPE → deposit to STEX AMM → LP shares
 * Instant withdraw: LP shares → withdraw(instant=true) → HYPE (with ~11bps fee)
 * Queued withdraw: LP shares → withdraw(instant=false) → claim later via WithdrawalModule
 */
contract ValantisPoolAdapter is
    IYieldSourceAdapter,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ==================== ROLES ====================
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ==================== STATE ====================

    // Valantis pool addresses
    address public stexPool;           // STEX AMM LP token + deposit/withdraw
    address public sovereignPool;      // For reserve queries (getReserves)
    address public withdrawalModule;   // For queued withdrawal claims

    // Token config
    address public whype;              // Wrapped HYPE
    address public stakingAccountant;  // For kHYPE → HYPE rate (zero for non-kHYPE pools)
    bool public isKHYPEPool;           // Whether token0 is kHYPE (needs accountant for pricing)

    // Tracking
    uint256 public totalDeposited;     // Cost basis in HYPE
    uint256 public nextTicketId;

    struct WithdrawalTicket {
        uint256 poolWithdrawalId;  // Valantis-side withdrawal ID
        uint256 expectedHype;
        bool claimed;
    }
    mapping(uint256 => WithdrawalTicket) public tickets;

    // Cached lending + unstaking reserves (updated on deposit/withdraw, avoids 367K gas Morpho queries)
    uint256 public cachedPendingUnstaking;
    uint256 public cachedLendingPool;

    // Storage gap (reduced by 2: __reserved_slot_1 → cachedPendingUnstaking, 1 gap → cachedLendingPool)
    uint256[38] private __gap;

    // ==================== EVENTS ====================
    event Deposited(uint256 hypeAmount, uint256 sharesReceived);
    event InstantWithdrawn(uint256 hypeAmount, uint256 hypeReceived);
    event WithdrawalQueued(uint256 indexed ticketId, uint256 hypeAmount);
    event WithdrawalClaimed(uint256 indexed ticketId, uint256 hypeReceived);

    // ==================== ERRORS ====================
    error ZeroAmount();
    error InsufficientReserves();
    error InvalidTicket();
    error AlreadyClaimed();
    error TransferFailed();
    error NotOperational();

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _stexPool,
        address _sovereignPool,
        address _withdrawalModule,
        address _whype,
        address _stakingAccountant,
        bool _isKHYPEPool,
        address _admin
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        stexPool = _stexPool;
        sovereignPool = _sovereignPool;
        withdrawalModule = _withdrawalModule;
        whype = _whype;
        stakingAccountant = _stakingAccountant;
        isKHYPEPool = _isKHYPEPool;
        nextTicketId = 1;
    }

    // ==================== IYieldSourceAdapter ====================

    /// @inheritdoc IYieldSourceAdapter
    function deposit() external payable override onlyRole(ROUTER_ROLE) returns (uint256 deposited) {
        if (msg.value == 0) revert ZeroAmount();
        if (!_isOperational()) revert NotOperational();

        deposited = msg.value;

        // HYPE → WHYPE → approve → deposit to STEX pool
        IWHYPE(whype).deposit{value: deposited}();
        IWHYPE(whype).approve(stexPool, deposited);
        uint256 shares = ISTEXAMM(stexPool).deposit(deposited, 0, block.timestamp + 300, address(this));

        totalDeposited += deposited;
        _updateCachedReserves();
        emit Deposited(deposited, shares);
    }

    /// @inheritdoc IYieldSourceAdapter
    function instantWithdraw(uint256 hypeAmount) external override onlyRole(ROUTER_ROLE) returns (uint256 hypeReceived) {
        if (hypeAmount == 0) revert ZeroAmount();

        uint256 reserve = _getReserveInHYPE();
        if (hypeAmount > reserve) revert InsufficientReserves();

        uint256 shares = _hypeToShares(hypeAmount);
        if (shares == 0) return 0;

        uint256 balBefore = address(this).balance;
        ISTEXAMM(stexPool).withdraw(shares, 0, 0, block.timestamp + 300, address(this), true, true);
        hypeReceived = address(this).balance - balBefore;

        _reduceDeposited(hypeAmount);
        _updateCachedReserves();

        // Forward HYPE to Router
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert TransferFailed();

        emit InstantWithdrawn(hypeAmount, hypeReceived);
    }

    /// @inheritdoc IYieldSourceAdapter
    function queueWithdraw(uint256 hypeAmount) external override onlyRole(ROUTER_ROLE) returns (uint256 ticketId) {
        if (hypeAmount == 0) revert ZeroAmount();

        uint256 reserve = _getReserveInHYPE();
        if (hypeAmount > reserve) revert InsufficientReserves();

        uint256 shares = _hypeToShares(hypeAmount);
        if (shares == 0) revert ZeroAmount();

        // Capture Valantis withdrawal ID before queuing
        uint256 poolWid = 0;
        if (withdrawalModule != address(0)) {
            poolWid = IValantisWithdrawalModule(withdrawalModule).nextWithdrawalId();
        }

        ISTEXAMM(stexPool).withdraw(shares, 0, 0, block.timestamp + 300, address(this), true, false);
        _reduceDeposited(hypeAmount);

        ticketId = nextTicketId++;
        tickets[ticketId] = WithdrawalTicket({
            poolWithdrawalId: poolWid,
            expectedHype: hypeAmount,
            claimed: false
        });

        emit WithdrawalQueued(ticketId, hypeAmount);
    }

    /// @inheritdoc IYieldSourceAdapter
    function claimWithdraw(uint256 ticketId) external override onlyRole(ROUTER_ROLE) returns (uint256 hypeReceived) {
        WithdrawalTicket storage ticket = tickets[ticketId];
        if (ticket.expectedHype == 0) revert InvalidTicket();
        if (ticket.claimed) revert AlreadyClaimed();

        uint256 balBefore = address(this).balance;

        if (ticket.poolWithdrawalId > 0 && withdrawalModule != address(0)) {
            IValantisWithdrawalModule(withdrawalModule).claim(ticket.poolWithdrawalId);
        }

        hypeReceived = address(this).balance - balBefore;
        ticket.claimed = true;

        // Forward to Router
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert TransferFailed();

        emit WithdrawalClaimed(ticketId, hypeReceived);
    }

    /// @inheritdoc IYieldSourceAdapter
    function getReserveInHYPE() external view override returns (uint256) {
        return _getReserveInHYPE();
    }

    /// @inheritdoc IYieldSourceAdapter
    function isOperational() external view override returns (bool) {
        return _isOperational();
    }

    /// @inheritdoc IYieldSourceAdapter
    function supportsInstantWithdraw() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IYieldSourceAdapter
    function getTotalDeposited() external view override returns (uint256) {
        return totalDeposited;
    }

    /**
     * @inheritdoc IYieldSourceAdapter
     * @dev If a withdrawalModule is configured and the ticket has a valid poolWithdrawalId,
     *      we attempt to query the module for readiness via a static call to `claim()`.
     *      Because IValantisWithdrawalModule does not expose an `isClaimable` view function,
     *      we use a try/catch staticcall: if claim() would succeed, the withdrawal is ready;
     *      if it reverts, it's not yet claimable. When no withdrawal module is set (instant-only
     *      pools) or the ticket has no pool-side ID, we return true optimistically.
     */
    function isWithdrawReady(uint256 ticketId) external view override returns (bool) {
        WithdrawalTicket memory ticket = tickets[ticketId];
        if (ticket.claimed || ticket.expectedHype == 0) return false;

        // If ticket has a pool-side withdrawal ID and withdrawal module is configured,
        // probe readiness via low-level staticcall to claim(). A staticcall executes the
        // function logic but discards state changes — if it would revert (e.g. "Not ready"),
        // we know the withdrawal isn't claimable yet.
        if (withdrawalModule != address(0) && ticket.poolWithdrawalId > 0) {
            // Probe readiness via staticcall. If the withdrawal module doesn't support
            // claim() (e.g., mock/instant-only pools), treat as ready (optimistic).
            (bool success, bytes memory returnData) = withdrawalModule.staticcall(
                abi.encodeWithSelector(IValantisWithdrawalModule.claim.selector, ticket.poolWithdrawalId)
            );
            // Only block if call executed but reverted with revert data (real "not ready").
            // Empty revert or missing function → treat as ready (instant pool / no queue).
            if (!success && returnData.length > 0) return false;
        }

        return true;
    }

    // ==================== INTERNAL ====================

    function _isOperational() internal view returns (bool) {
        return stexPool != address(0) && sovereignPool != address(0) && whype != address(0) && !paused();
    }

    function _getReserveInHYPE() internal view returns (uint256) {
        if (stexPool == address(0) || sovereignPool == address(0)) return 0;

        uint256 ourShares = IERC20(stexPool).balanceOf(address(this));
        if (ourShares == 0) return 0;

        uint256 supply = ISTEXAMM(stexPool).totalSupply();
        if (supply == 0) return 0;

        uint256 poolValue = _getPoolValueInHYPE();
        return (poolValue * ourShares) / supply;
    }

    function _getPoolValueInHYPE() internal view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = ISovereignPool(sovereignPool).getReserves();

        // Include cached lending + unstaking reserves.
        // These are updated on deposit/withdraw via _updateCachedReserves().
        // Using cached values saves ~360K gas per call vs live Morpho queries.
        reserve0 += cachedPendingUnstaking;
        reserve1 += cachedLendingPool;

        uint256 reserve0InHYPE;
        if (isKHYPEPool && stakingAccountant != address(0) && reserve0 > 0) {
            reserve0InHYPE = IStakingAccountant(stakingAccountant).kHYPEToHYPE(reserve0);
        } else {
            reserve0InHYPE = reserve0;
        }

        return reserve0InHYPE + reserve1;
    }

    /// @dev Update cached lending + unstaking values from STEX withdrawal module
    function _updateCachedReserves() internal {
        try ISTEXAMM(stexPool).withdrawalModule() returns (address wm) {
            if (wm != address(0)) {
                try IValantisWithdrawalModule(wm).amountToken0PendingUnstaking() returns (uint256 v) {
                    cachedPendingUnstaking = v;
                } catch {}
                try IValantisWithdrawalModule(wm).amountToken1LendingPool() returns (uint256 v) {
                    cachedLendingPool = v;
                } catch {}
            }
        } catch {}
    }

    function _hypeToShares(uint256 hypeAmount) internal view returns (uint256) {
        uint256 supply = ISTEXAMM(stexPool).totalSupply();
        if (supply == 0) return hypeAmount;

        uint256 poolValue = _getPoolValueInHYPE();
        if (poolValue == 0) return 0;

        uint256 shares = (hypeAmount * supply) / poolValue;

        // Cap to our actual balance
        uint256 ourShares = IERC20(stexPool).balanceOf(address(this));
        return shares > ourShares ? ourShares : shares;
    }

    function _reduceDeposited(uint256 hypeAmount) internal {
        totalDeposited = totalDeposited >= hypeAmount ? totalDeposited - hypeAmount : 0;
    }

    // ==================== ADMIN ====================

    /// @notice Refresh cached lending + unstaking reserves (one-time after upgrade)
    function refreshCachedReserves() external onlyRole(ADMIN_ROLE) {
        _updateCachedReserves();
    }

    function setPoolConfig(
        address _stexPool,
        address _sovereignPool,
        address _withdrawalModule,
        address _stakingAccountant,
        address _whype
    ) external onlyRole(ADMIN_ROLE) {
        stexPool = _stexPool;
        sovereignPool = _sovereignPool;
        withdrawalModule = _withdrawalModule;
        stakingAccountant = _stakingAccountant;
        whype = _whype;
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    receive() external payable {}
}
