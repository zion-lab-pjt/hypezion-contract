// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IDexIntegration
 * @notice Interface for DEX integrations to execute swaps for instant redemptions
 * @dev Uses pre-encoded swap data from off-chain KyberSwap API for optimal routing
 *
 * API Flow:
 * 1. Frontend: GET /api/v1/routes → routeSummary
 * 2. Frontend: POST /api/v1/route/build → encodedSwapData
 * 3. Contract: executeSwap() → calls KyberSwap router with encodedSwapData
 */
interface IDexIntegration {
    // ==================== Events ====================

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ExchangeUpdated(address indexed oldExchange, address indexed newExchange);

    // ==================== Errors ====================

    error UnauthorizedCaller(address caller);
    error InvalidRouter(address router);
    error InvalidToken(address token);
    error InvalidAmount(uint256 amount);
    error InsufficientBalance(uint256 balance, uint256 required);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error SwapFailed(string reason);
    error InsufficientOutput(uint256 expected, uint256 actual);
    error InsufficientSwapReturnAmount(uint256 expected, uint256 actual);
    error InsufficientBalanceIncrease(uint256 expected, uint256 actual);

    // ==================== Core Functions ====================

    /**
     * @notice Execute a swap on KyberSwap using pre-encoded route data from API
     * @dev Frontend must call KyberSwap API to get encodedSwapData:
     *      1. GET /api/v1/routes (tokenIn, tokenOut, amountIn) → routeSummary
     *      2. POST /api/v1/route/build (routeSummary, sender, recipient, slippage) → encodedSwapData
     *
     * @param encodedSwapData Complete ABI-encoded calldata from KyberSwap API (includes function selector)
     * @param tokenIn Address of input token (use 0xEeee...eEeE for native HYPE)
     * @param tokenOut Address of output token (use 0xEeee...eEeE for native HYPE)
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
    ) external payable returns (uint256 amountOut);

    // ==================== View Functions ====================

    /**
     * @notice Get the KyberSwap router address
     * @return router Address of MetaAggregationRouterV2
     */
    function getRouterAddress() external view returns (address router);

    /**
     * @notice Get the authorized exchange address
     * @return exchange Address that can call executeSwap
     */
    function getExchange() external view returns (address exchange);

    /**
     * @notice Check if integration is active and operational
     * @return isActive True if router is set and integration is not paused
     */
    function isActive() external view returns (bool isActive);

    // ==================== Admin Functions ====================

    /**
     * @notice Set the KyberSwap router address
     * @param _router MetaAggregationRouterV2 address
     */
    function setRouter(address _router) external;

    /**
     * @notice Set the authorized Exchange address that can call executeSwap
     * @param _exchange Exchange contract address
     */
    function setExchange(address _exchange) external;

    /**
     * @notice Swap HYPE to kHYPE directly via DEX
     * @dev Replaces the old Kinetiq staking flow with direct DEX swap
     * @param swapData Encoded swap data from DEX API (HYPE → kHYPE)
     * @param minKHypeOut Minimum kHYPE to receive (slippage protection)
     * @return kHypeReceived Amount of kHYPE received after fee
     */
    function swapToKHype(
        bytes calldata swapData,
        uint256 minKHypeOut
    ) external payable returns (uint256 kHypeReceived);

    /**
     * @notice Emergency function to rescue stuck tokens
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueFunds(address token, uint256 amount) external;
}
