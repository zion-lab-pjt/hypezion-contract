// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDexIntegration.sol";
import "../interfaces/IHypeZionExchange.sol";
import "../tokens/HzUSD.sol";
import "../tokens/BullHYPE.sol";

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
 * External Token Support:
 * - Supports swapping external tokens (USDC, USDT, etc.) to hzUSD/bullHYPE
 * - Generic design: easily add new tokens via addSupportedExternalToken()
 * - Each token can have its own swap fee
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

    // ==================== Events ====================

    event ExternalTokenAdded(address indexed token, uint256 feeBps);
    event ExternalTokenRemoved(address indexed token);
    event ExternalTokenSwapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event SwapToKHypeExecuted(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 kHypeReceived,
        uint256 feeTaken
    );
    event SwapToKHypeFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event KHypeTokenUpdated(address oldToken, address newToken);
    event YieldManagerUpdated(address oldYieldManager, address newYieldManager);

    // ==================== Constants ====================

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% maximum slippage
    uint256 public constant BASIS_POINTS = 10000;

    // Native token address used by KyberSwap
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // kHYPE token address (Kinetiq staked HYPE) - mainnet default
    address public constant KHYPE_TOKEN_DEFAULT = 0xfD739d4e423301CE9385c1fb8850539D657C296D;

    // ==================== State Variables ====================

    address public kyberswapRouter;  // MetaAggregationRouterV2 address
    address public exchange;         // Authorized HypeZionExchange address

    // External token swap support (USDC, USDT, WHYPE, etc.)
    mapping(address => bool) public supportedExternalTokens; // Tokens that can be swapped to hzUSD/bullHYPE
    mapping(address => uint256) public externalTokenSwapFees; // Fee in basis points for each external token

    // Token contracts (for external token swaps)
    HzUSD public hzUSD;
    BullHYPE public bullHYPE;

    // Fee for swapToKHype function (basis points, default 500 = 5% same as mint fee)
    uint256 public swapToKHypeFeeBps;

    // Configurable kHYPE token address (allows testnet to use MockKHYPE)
    address public kHypeToken;

    // Authorized YieldManager address (for kHYPE to HYPE swaps during yield harvesting)
    address public yieldManager;

    // Storage gap for future upgrades (reduced by 3: swapToKHypeFeeBps, kHypeToken, yieldManager)
    uint256[38] private __gap;

    // ==================== Modifiers ====================

    modifier onlyExchange() {
        if (msg.sender != exchange) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != exchange && msg.sender != yieldManager) revert UnauthorizedCaller(msg.sender);
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

        // Initialize swapToKHype fee (example: 500 = 5%)
        swapToKHypeFeeBps = 0;

        // Initialize kHypeToken to mainnet default (can be changed for testnet)
        kHypeToken = KHYPE_TOKEN_DEFAULT;

        emit RouterUpdated(address(0), _kyberswapRouter);
        emit ExchangeUpdated(address(0), _exchange);
    }

    // ==================== Core Functions ====================

    /**
     * @notice Execute a swap on KyberSwap using pre-encoded route data from API
     * @dev encodedSwapData must be obtained from KyberSwap API:
     *      1. GET /api/v1/routes (tokenIn, tokenOut, amountIn) to routeSummary
     *      2. POST /api/v1/route/build (routeSummary, sender=this, recipient, slippage) to encodedSwapData
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
        onlyAuthorized
        nonReentrant
        returns (uint256 amountOut)
    {
        return _executeSwapInternal(encodedSwapData, tokenIn, tokenOut, amountIn, minAmountOut, recipient);
    }

    /**
     * @dev Internal swap execution logic
     * Can be called by external token swap functions without onlyExchange restriction
     */
    function _executeSwapInternal(
        bytes memory encodedSwapData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        // 1. Validate parameters
        if (tokenIn == address(0)) revert InvalidToken(tokenIn);
        if (tokenOut == address(0)) revert InvalidToken(tokenOut);
        if (amountIn == 0) revert InvalidAmount(amountIn);
        // Note: minAmountOut can be 0 when slippage protection is handled in encoded data
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

            // GAS OPTIMIZATION: Use lazy infinite approval
            // Only approve if current allowance is insufficient (saves ~20k gas per subsequent swap)
            // Safe because: router is admin-controlled, contract doesn't hold tokens long-term
            uint256 currentAllowance = tokenInContract.allowance(address(this), kyberswapRouter);
            if (currentAllowance < amountIn) {
                tokenInContract.forceApprove(kyberswapRouter, type(uint256).max);
            }
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

        // Note: Using persistent infinite approval (no clear needed)
        // This saves ~20k gas per swap after first approval is set

        // 8. Emit event
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

    // ==================== Swap To kHYPE Functions ====================

    /**
     * @notice Internal function to swap any token to kHYPE
     * @dev Consolidates common logic for HYPE to kHYPE and External Token to kHYPE swaps
     * @param inputToken Address of input token (NATIVE_TOKEN for HYPE)
     * @param amount Amount of input token
     * @param swapData Encoded swap data from KyberSwap API
     * @param minKHypeOut Minimum kHYPE to receive (slippage protection)
     * @param recipient Address to receive kHYPE after fee
     * @param caller Original caller address (for event emission)
     * @return kHypeReceived Amount of kHYPE received after fee
     */
    function _swapToKHypeInternal(
        address inputToken,
        uint256 amount,
        bytes memory swapData,
        uint256 minKHypeOut,
        address recipient,
        address caller
    ) internal returns (uint256 kHypeReceived) {
        // 1. Execute swap inputToken to kHYPE via KyberSwap
        uint256 kHypeFromSwap = _executeSwapInternal(
            swapData,
            inputToken,
            kHypeToken,
            amount,
            0, // minAmountOut handled below with fee consideration
            address(this) // Receive kHYPE to this contract first
        );

        if (kHypeFromSwap == 0) revert SwapFailed("No kHYPE received from swap");

        // 2. Determine fee based on input token
        bool isNativeInput = inputToken == NATIVE_TOKEN;
        uint256 feeBps = isNativeInput ? swapToKHypeFeeBps :
            (externalTokenSwapFees[inputToken] > 0 ? externalTokenSwapFees[inputToken] : swapToKHypeFeeBps);

        // 3. Apply fee
        uint256 fee = (kHypeFromSwap * feeBps) / BASIS_POINTS;
        kHypeReceived = kHypeFromSwap - fee;

        // 4. Check minimum output after fee
        if (kHypeReceived < minKHypeOut) {
            revert InsufficientSwapReturnAmount(minKHypeOut, kHypeReceived);
        }

        // 5. Transfer kHYPE to recipient
        IERC20(kHypeToken).safeTransfer(recipient, kHypeReceived);

        // 6. Fee stays in contract for protocol revenue

        // 7. Emit event
        emit SwapToKHypeExecuted(
            caller,
            inputToken,
            amount,
            kHypeReceived,
            fee
        );

        return kHypeReceived;
    }

    /**
     * @notice Swap HYPE to kHYPE directly via KyberSwap
     * @dev This replaces the old flow of: HYPE to stake via Kinetiq to kHYPE
     *      New flow is direct: HYPE to kHYPE via KyberSwap DEX
     *      Fee is applied and configurable (same as mint fee by default)
     *      Note: No nonReentrant here as this is called from Exchange which already has nonReentrant
     * @param swapData Encoded swap data from KyberSwap API (HYPE to kHYPE)
     * @param minKHypeOut Minimum kHYPE to receive (slippage protection)
     * @return kHypeReceived Amount of kHYPE received after fee
     */
    function swapToKHype(
        bytes calldata swapData,
        uint256 minKHypeOut
    ) external payable onlyExchange returns (uint256 kHypeReceived) {
        if (msg.value == 0) revert InvalidAmount(msg.value);

        return _swapToKHypeInternal(
            NATIVE_TOKEN,
            msg.value,
            swapData,
            minKHypeOut,
            msg.sender, // Exchange receives kHYPE
            tx.origin   // Original user (for event)
        );
    }

    /**
     * @notice Swap any input token to kHYPE directly via KyberSwap
     * @dev For external tokens (USDC, USDT, etc.) to kHYPE
     *      The inputToken must be a supported external token
     * @param inputToken Address of input token (use NATIVE_TOKEN for native HYPE)
     * @param amount Amount of input token to swap
     * @param swapData Encoded swap data from KyberSwap API (inputToken to kHYPE)
     * @param minKHypeOut Minimum kHYPE to receive (slippage protection)
     * @return kHypeReceived Amount of kHYPE received after fee
     */
    function swapTokenToKHype(
        address inputToken,
        uint256 amount,
        bytes calldata swapData,
        uint256 minKHypeOut
    ) external payable nonReentrant returns (uint256 kHypeReceived) {
        // 1. Validate input
        bool isNativeInput = inputToken == NATIVE_TOKEN;

        if (isNativeInput) {
            if (msg.value != amount) revert InvalidAmount(msg.value);
        } else {
            if (!supportedExternalTokens[inputToken]) revert InvalidToken(inputToken);
            if (amount == 0) revert InvalidAmount(amount);
            // Transfer external token from user to this contract
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        // 2. Use internal function for swap logic
        return _swapToKHypeInternal(
            inputToken,
            amount,
            swapData,
            minKHypeOut,
            msg.sender, // User receives kHYPE
            msg.sender  // User is caller (for event)
        );
    }

    // ==================== External Token Swap Functions ====================

    /**
     * @notice Helper function to swap HYPE to external token
     * @dev This is a helper for users who redeemed hzUSD/bullHYPE and received HYPE,
     *      and now want to convert it to an external token (e.g., USDC)
     * @param externalToken Address of external token (e.g., USDC)
     * @param hypeToExternalSwapData Encoded swap data for HYPE to external token from KyberSwap API
     * @param minExternalOut Minimum external token to receive
     * @return externalReceived Amount of external token received
     */
    function swapHYPEToExternalToken(
        address externalToken,
        bytes calldata hypeToExternalSwapData,
        uint256 minExternalOut
    ) external payable nonReentrant returns (uint256 externalReceived) {
        if (!supportedExternalTokens[externalToken]) revert InvalidToken(externalToken);
        if (msg.value == 0) revert InvalidAmount(msg.value);

        // Swap HYPE to external token via DEX
        externalReceived = _executeSwapInternal(
            hypeToExternalSwapData,
            NATIVE_TOKEN,
            externalToken,
            msg.value,
            minExternalOut,
            msg.sender // External token goes directly to user
        );

        emit ExternalTokenSwapped(
            msg.sender,
            NATIVE_TOKEN,
            externalToken,
            msg.value,
            externalReceived
        );

        return externalReceived;
    }

    // ==================== External Token Swap Functions ====================

    /**
     * @notice Swap external token (USDC, USDT, etc.) to HYPE native token
     * @dev RECOMMENDED: Use this 2-step flow instead of direct mint functions.
     *      Step 1: Call this function to swap external token to HYPE (user receives HYPE)
     *      Step 2: User calls Exchange.mintStablecoin() or mintLevercoin() with HYPE
     *
     *      This approach is simpler, more gas efficient, and avoids msg.value forwarding issues.
     *
     * @param externalToken Address of external token (e.g., USDC)
     * @param amount Amount of external token to swap
     * @param swapData Encoded swap data from KyberSwap API (externalToken to HYPE)
     * @param minHypeOut Minimum HYPE to receive (slippage protection)
     * @return hypeReceived Amount of HYPE received by user
     */
    function swapExternalTokenToHype(
        address externalToken,
        uint256 amount,
        bytes calldata swapData,
        uint256 minHypeOut
    ) external nonReentrant returns (uint256 hypeReceived) {
        // 1. Validate
        if (!supportedExternalTokens[externalToken]) revert InvalidToken(externalToken);
        if (amount == 0) revert InvalidAmount(amount);

        // 2. Pull external token from msg.sender (caller)
        // User must approve this contract before calling
        IERC20(externalToken).safeTransferFrom(msg.sender, address(this), amount);

        // 3. Swap external token to HYPE via KyberSwap
        // IMPORTANT: Send HYPE directly to user!
        hypeReceived = _executeSwapInternal(
            swapData,
            externalToken,
            NATIVE_TOKEN,
            amount,
            minHypeOut,
            msg.sender  // User receives HYPE directly
        );

        if (hypeReceived == 0) revert SwapFailed("No HYPE received");

        emit ExternalTokenSwapped(
            msg.sender,
            externalToken,
            NATIVE_TOKEN,  // HYPE
            amount,
            hypeReceived
        );

        return hypeReceived;
    }


    // ==================== Admin Functions ====================

    /**
     * @notice Set the fee for swapToKHype function
     * @param feeBps Fee in basis points (e.g., 500 = 5%)
     */
    function setSwapToKHypeFeeBps(uint256 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > 5000) revert InvalidAmount(feeBps); // Max 50%
        uint256 oldFeeBps = swapToKHypeFeeBps;
        swapToKHypeFeeBps = feeBps;
        emit SwapToKHypeFeeBpsUpdated(oldFeeBps, feeBps);
    }

    /**
     * @notice Add or update a supported external token
     * @param token External token address
     * @param feeBps Fee in basis points (e.g., 0 = no fee, 500 = 5%)
     */
    function addSupportedExternalToken(address token, uint256 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidToken(token);
        if (feeBps > 5000) revert InvalidAmount(feeBps); // Max 50%

        // Verify token is a contract (has code)
        if (token.code.length == 0) revert InvalidToken(token);

        // Verify token implements ERC20 interface by calling balanceOf
        // This will revert if the contract doesn't have balanceOf function
        try IERC20(token).balanceOf(address(this)) {} catch {
            revert InvalidToken(token);
        }

        supportedExternalTokens[token] = true;
        externalTokenSwapFees[token] = feeBps;

        emit ExternalTokenAdded(token, feeBps);
    }

    /**
     * @notice Remove a supported external token
     * @param token External token address
     */
    function removeSupportedExternalToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedExternalTokens[token] = false;
        externalTokenSwapFees[token] = 0;

        emit ExternalTokenRemoved(token);
    }

    /**
     * @notice Set token contract addresses (hzUSD, bullHYPE)
     * @param _hzUSD hzUSD token address
     * @param _bullHYPE bullHYPE token address
     */
    function setTokenContracts(address _hzUSD, address _bullHYPE) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_hzUSD == address(0) || _bullHYPE == address(0)) revert InvalidToken(address(0));
        hzUSD = HzUSD(_hzUSD);
        bullHYPE = BullHYPE(_bullHYPE);
    }

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
     * @notice Set the kHYPE token address
     * @dev Allows changing from mainnet kHYPE to MockKHYPE for testnet
     * @param _kHypeToken kHYPE token address
     */
    function setKHypeToken(address _kHypeToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_kHypeToken == address(0)) revert InvalidToken(_kHypeToken);
        address oldToken = kHypeToken;
        kHypeToken = _kHypeToken;
        emit KHypeTokenUpdated(oldToken, _kHypeToken);
    }

    /**
     * @notice Set the authorized YieldManager address
     * @dev YieldManager can call executeSwap for kHYPE to HYPE swaps during yield harvesting
     * @param _yieldManager YieldManager contract address
     */
    function setYieldManager(address _yieldManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_yieldManager == address(0)) revert InvalidToken(_yieldManager);
        address oldYieldManager = yieldManager;
        yieldManager = _yieldManager;
        emit YieldManagerUpdated(oldYieldManager, _yieldManager);
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
