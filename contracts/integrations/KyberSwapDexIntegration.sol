// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDexIntegration.sol";

/**
 * @title KyberSwapDexIntegration
 * @notice Integration with KyberSwap MetaAggregationRouterV2 for instant token swaps
 * @dev Implements IDexIntegration interface with UUPS upgradeability
 *
 * Architecture:
 * - Frontend calls KyberSwap API to get optimal route and encoded swap data
 * - Frontend passes encodedSwapData to this contract via HypeZionExchange
 * - Contract validates parameters and executes swap via low-level call
 * - No on-chain quoting needed (handled off-chain by KyberSwap API)
 *
 * Security Features:
 * - Only authorized Exchange can execute swaps
 * - ReentrancyGuard on all external calls
 * - Router address validation
 * - Token and amount validation
 * - Slippage protection via minAmountOut
 * - Balance verification before/after
 * - Approval management (approve exact amount, clear after)
 * - Low-level call result verification
 */
contract KyberSwapDexIntegration is
    IDexIntegration,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ==================== Constants ====================

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% maximum slippage
    uint256 public constant BASIS_POINTS = 10000;

    // Native token address used by KyberSwap
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ==================== State Variables ====================

    address public kyberswapRouter;  // MetaAggregationRouterV2 address
    address public exchange;         // Authorized HypeZionExchange address

    // Storage gap for future upgrades
    uint256[46] private __gap;

    // ==================== Modifiers ====================

    modifier onlyExchange() {
        if (msg.sender != exchange) revert UnauthorizedCaller(msg.sender);
        _;
    }

    // ==================== Initialization ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the DEX integration
     * @param _kyberswapRouter KyberSwap MetaAggregationRouterV2 address
     * @param _exchange HypeZionExchange address
     */
    function initialize(
        address _kyberswapRouter,
        address _exchange
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        if (_kyberswapRouter == address(0)) revert InvalidRouter(_kyberswapRouter);
        // Exchange can be zero initially, will be set later via setExchange()

        kyberswapRouter = _kyberswapRouter;
        exchange = _exchange;

        emit RouterUpdated(address(0), _kyberswapRouter);
        emit ExchangeUpdated(address(0), _exchange);
    }

    // ==================== Core Functions ====================

    /**
     * @notice Execute a swap on KyberSwap using pre-encoded route data from API
     * @dev encodedSwapData must be obtained from KyberSwap API:
     *      1. GET /api/v1/routes (tokenIn, tokenOut, amountIn) → routeSummary
     *      2. POST /api/v1/route/build (routeSummary, sender=this, recipient, slippage) → encodedSwapData
     *
     * @param encodedSwapData Complete ABI-encoded calldata from KyberSwap API (includes function selector)
     * @param tokenIn Address of input token (use NATIVE_TOKEN for native HYPE)
     * @param tokenOut Address of output token (use NATIVE_TOKEN for native HYPE)
     * @param amountIn Amount of input tokens (for validation and approval)
     * @param minAmountOut Minimum acceptable output amount (slippage protection)
     * @param recipient Address to receive output tokens (for validation)
     * @return amountOut Actual amount of output tokens received
     */
    function executeSwap(
        bytes calldata encodedSwapData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        payable
        override
        onlyExchange
        nonReentrant
        returns (uint256 amountOut)
    {
        // 1. Validate parameters
        if (tokenIn == address(0)) revert InvalidToken(tokenIn);
        if (tokenOut == address(0)) revert InvalidToken(tokenOut);
        if (amountIn == 0) revert InvalidAmount(amountIn);
        if (minAmountOut == 0) revert InvalidAmount(minAmountOut);
        if (recipient == address(0)) revert InvalidToken(recipient);
        if (encodedSwapData.length == 0) revert SwapFailed("Empty encoded data");

        // 2. Get balances before swap
        uint256 balanceOutBefore;
        if (tokenOut == NATIVE_TOKEN) {
            balanceOutBefore = recipient.balance;
        } else {
            balanceOutBefore = IERC20(tokenOut).balanceOf(recipient);
        }

        // 3. Handle input tokens
        bool isNativeInput = tokenIn == NATIVE_TOKEN;

        if (isNativeInput) {
            // For native HYPE: verify msg.value matches amountIn
            if (msg.value != amountIn) revert InvalidAmount(msg.value);
        } else {
            // For ERC20: tokens should already be in this contract (Exchange sends them first)
            // Verify we have the tokens
            IERC20 tokenInContract = IERC20(tokenIn);
            uint256 balance = tokenInContract.balanceOf(address(this));
            if (balance < amountIn) revert InsufficientBalance(balance, amountIn);

            // Approve KyberSwap router to spend input tokens
            tokenInContract.forceApprove(kyberswapRouter, amountIn);
        }

        // 4. Execute swap via low-level call with encoded data from API
        // encodedSwapData already contains the complete function call:
        // - Function selector (first 4 bytes) for swap(SwapExecutionParams)
        // - ABI-encoded SwapExecutionParams struct
        uint256 valueToSend = isNativeInput ? amountIn : 0;
        (bool success, bytes memory result) = kyberswapRouter.call{value: valueToSend}(encodedSwapData);

        if (!success) {
            // Decode revert reason if available
            if (result.length > 0) {
                assembly {
                    let resultSize := mload(result)
                    revert(add(32, result), resultSize)
                }
            }
            revert SwapFailed("Swap execution failed");
        }

        // 5. Decode return value: (uint256 returnAmount, uint256 gasUsed)
        (uint256 returnAmount, ) = abi.decode(result, (uint256, uint256));
        amountOut = returnAmount;

        // 6. Verify output amount meets minimum requirement
        if (amountOut < minAmountOut) {
            revert InsufficientSwapReturnAmount(minAmountOut, amountOut);
        }

        // 7. Verify balance increased as expected
        uint256 balanceOutAfter;
        if (tokenOut == NATIVE_TOKEN) {
            balanceOutAfter = recipient.balance;
        } else {
            balanceOutAfter = IERC20(tokenOut).balanceOf(recipient);
        }

        uint256 actualReceived = balanceOutAfter - balanceOutBefore;

        if (actualReceived < minAmountOut) {
            revert InsufficientBalanceIncrease(minAmountOut, actualReceived);
        }

        // 8. Clear approval (security best practice, ERC20 only)
        if (!isNativeInput) {
            IERC20(tokenIn).forceApprove(kyberswapRouter, 0);
        }

        // 10. Emit event
        emit SwapExecuted(
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            recipient
        );

        return amountOut;
    }

    // ==================== View Functions ====================

    /**
     * @notice Get the KyberSwap router address
     * @return router Address of MetaAggregationRouterV2
     */
    function getRouterAddress() external view override returns (address router) {
        return kyberswapRouter;
    }

    /**
     * @notice Get the authorized exchange address
     * @return _exchange Address that can call executeSwap
     */
    function getExchange() external view override returns (address _exchange) {
        return exchange;
    }

    /**
     * @notice Check if integration is active and operational
     * @return _isActive True if router is set and integration is not paused
     */
    function isActive() external view override returns (bool _isActive) {
        return kyberswapRouter != address(0) && exchange != address(0);
    }

    // ==================== Admin Functions ====================

    /**
     * @notice Set the KyberSwap router address
     * @param _router MetaAggregationRouterV2 address
     */
    function setRouter(address _router) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_router == address(0)) revert InvalidRouter(_router);
        address oldRouter = kyberswapRouter;
        kyberswapRouter = _router;
        emit RouterUpdated(oldRouter, _router);
    }

    /**
     * @notice Set the authorized Exchange address
     * @param _exchange Exchange contract address
     */
    function setExchange(address _exchange) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_exchange == address(0)) revert InvalidToken(_exchange);
        address oldExchange = exchange;
        exchange = _exchange;
        emit ExchangeUpdated(oldExchange, _exchange);
    }

    /**
     * @notice Emergency function to rescue stuck tokens
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueFunds(address token, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    // ==================== UUPS Upgrade ====================

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    // ==================== Receive Function ====================

    receive() external payable {}
}
