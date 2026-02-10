// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMetaAggregationRouterV2.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "./MockKHYPE.sol";

/**
 * @title MockKyberSwapRouter
 * @notice Mock implementation of KyberSwap MetaAggregationRouterV2 for testnet
 * @dev Frontend calls real KyberSwap API to get routes and encoded swap data,
 *      but this mock contract executes swaps using simple 1:1 rates for testing.
 *
 * Architecture:
 * - Frontend: Calls KyberSwap API normally (gets routes, builds swap data)
 * - DexIntegration: Calls this router with encoded data (same as mainnet)
 * - This contract: Decodes params, executes swaps with 1:1 rate
 *
 * Supported swaps:
 * - mkHYPE → HYPE (redemption flow)
 * - HYPE → mkHYPE (minting flow)
 * - External tokens (USDC, USDT, etc.) → HYPE (first step of 2-swap flow)
 */
contract MockKyberSwapRouter is IMetaAggregationRouterV2, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ==================== State Variables ====================

    IKinetiqIntegration public kinetiqIntegration;
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Generic external token support (USDC, USDT, etc.)
    mapping(address => bool) public supportedExternalTokens;  // Supported external tokens
    mapping(address => uint256) public externalTokenRates;    // Token/HYPE rates (scaled by 1e18)
    mapping(address => uint8) public externalTokenDecimals;   // Token decimals

    // ==================== Errors ====================

    error InvalidTokenPair(address srcToken, address dstToken);
    error InsufficientReturnAmount(uint256 returnAmount, uint256 minReturnAmount);
    error SwapFailed(string reason);
    error ZeroAddress();

    // ==================== Events ====================

    event KinetiqIntegrationUpdated(address indexed newKinetiqIntegration);
    event ExternalTokenAdded(address indexed token, uint256 rate, uint8 decimals);
    event ExternalTokenRemoved(address indexed token);
    event ExternalTokenRateUpdated(address indexed token, uint256 newRate);

    // Storage gap for future upgrades
    uint256[50] private __gap;

    // ==================== Constructor ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the mock router
     * @param _kinetiqIntegration Kinetiq integration address
     * @param _owner Owner address for access control
     */
    function initialize(
        address _kinetiqIntegration,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        if (_kinetiqIntegration == address(0)) revert ZeroAddress();
        kinetiqIntegration = IKinetiqIntegration(_kinetiqIntegration);
    }

    // ==================== Main Swap Function ====================

    /**
     * @notice Execute token swap using Kinetiq exchange rate
     * @dev Accepts KyberSwap-encoded data but performs simple swap based on Kinetiq rate
     *      Frontend still calls KyberSwap API to build params, we just ignore complex routing
     *
     * @param execution Swap execution params from KyberSwap API
     * @return returnAmount Actual amount of destination tokens received
     * @return gasUsed Gas consumed (mock value)
     */
    function swap(SwapExecutionParams calldata execution)
        external
        payable
        override
        returns (uint256 returnAmount, uint256 gasUsed)
    {
        SwapDescriptionV2 memory desc = execution.desc;

        // Validate tokens
        address srcToken = address(desc.srcToken);
        address dstToken = address(desc.dstToken);
        address mkHYPE = kinetiqIntegration.getKHypeAddress();

        // Determine swap direction
        bool isMkHYPEtoHYPE = (srcToken == mkHYPE && dstToken == NATIVE_TOKEN);
        bool isHYPEtoMkHYPE = (srcToken == NATIVE_TOKEN && dstToken == mkHYPE);
        bool isExternalToHYPE = (supportedExternalTokens[srcToken] && dstToken == NATIVE_TOKEN);

        if (!isMkHYPEtoHYPE && !isHYPEtoMkHYPE && !isExternalToHYPE) {
            revert InvalidTokenPair(srcToken, dstToken);
        }

        // Determine amountIn based on swap direction
        // For native: use msg.value or desc.amount
        // For ERC20: use sender's actual balance (handles rounding differences)
        uint256 amountIn;
        if (srcToken == NATIVE_TOKEN) {
            amountIn = msg.value > 0 ? msg.value : desc.amount;
        } else {
            // For ERC20 swaps: use min(desc.amount, sender's balance) to handle rounding
            uint256 senderBalance = IERC20(srcToken).balanceOf(msg.sender);
            amountIn = senderBalance < desc.amount ? senderBalance : desc.amount;
        }

        uint256 PRECISION = 1e18;

        // Calculate output amount based on swap direction
        if (isMkHYPEtoHYPE) {
            // mkHYPE → HYPE: Use Kinetiq exchange rate for realistic swap simulation
            // This ensures the mock behaves consistently with HypeZionExchange's rate divergence check
            uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
            returnAmount = (amountIn * exchangeRate) / PRECISION;

            // Transfer mkHYPE from sender to this contract
            IERC20(mkHYPE).safeTransferFrom(msg.sender, address(this), amountIn);

            // Burn the mkHYPE (simulate redemption)
            MockKHYPE(mkHYPE).burn(amountIn);

            // Get HYPE from KinetiqIntegration (which holds staked HYPE)
            // This simulates getting HYPE from the actual staking contract
            (bool requestSuccess, ) = address(kinetiqIntegration).call(
                abi.encodeWithSignature("withdrawHYPEForSwap(uint256)", returnAmount)
            );
            if (!requestSuccess) {
                // Fallback: use contract's own balance if KinetiqIntegration doesn't support withdrawal
                if (address(this).balance < returnAmount) {
                    revert SwapFailed("Insufficient HYPE reserves");
                }
            }

            // Transfer HYPE to recipient
            (bool success, ) = payable(desc.dstReceiver).call{value: returnAmount}("");
            if (!success) revert SwapFailed("HYPE transfer failed");

        } else if (isHYPEtoMkHYPE) {
            // HYPE → mkHYPE: Use Kinetiq exchange rate for realistic swap simulation
            // exchangeRate = HYPE per kHYPE, so mkHYPE = HYPE * 1e18 / exchangeRate
            // Note: amountIn is already set to msg.value for native tokens

            // Calculate mkHYPE output using exchange rate (inverse of mkHYPE → HYPE)
            uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
            returnAmount = (amountIn * PRECISION) / exchangeRate;

            // Mint mkHYPE to recipient
            // Note: This contract must be added as minter via MockKHYPE.addMinter()
            MockKHYPE(mkHYPE).mint(desc.dstReceiver, returnAmount);

        } else if (isExternalToHYPE) {
            // External Token → HYPE (generic for USDC, USDT, etc.)
            uint256 tokenRate = externalTokenRates[srcToken];
            uint8 tokenDecimals = externalTokenDecimals[srcToken];

            // Calculate decimal difference and scale accordingly
            // amountOut = amountIn * tokenRate * 10^(18-tokenDecimals) / 1e18
            uint256 decimalScale = 10 ** (18 - tokenDecimals);
            returnAmount = (amountIn * tokenRate * decimalScale) / PRECISION;

            // Transfer external token from sender to this contract
            IERC20(srcToken).safeTransferFrom(msg.sender, address(this), amountIn);

            // Transfer HYPE to recipient
            if (address(this).balance < returnAmount) {
                revert SwapFailed("Insufficient HYPE reserves");
            }
            (bool success, ) = payable(desc.dstReceiver).call{value: returnAmount}("");
            if (!success) revert SwapFailed("HYPE transfer failed");
        }

        // Verify minimum return amount
        if (returnAmount < desc.minReturnAmount) {
            revert InsufficientReturnAmount(returnAmount, desc.minReturnAmount);
        }

        // Emit event
        emit Swapped(
            msg.sender,
            desc.srcToken,
            desc.dstToken,
            desc.dstReceiver,
            amountIn,
            returnAmount
        );

        // Mock gas used
        gasUsed = 250000;

        return (returnAmount, gasUsed);
    }

    // ==================== Admin Functions ====================

    /**
     * @notice Update Kinetiq integration address
     * @param _kinetiqIntegration New Kinetiq integration address
     */
    function setKinetiqIntegration(address _kinetiqIntegration) external onlyOwner {
        if (_kinetiqIntegration == address(0)) revert ZeroAddress();
        kinetiqIntegration = IKinetiqIntegration(_kinetiqIntegration);
        emit KinetiqIntegrationUpdated(_kinetiqIntegration);
    }

    /**
     * @notice Add or update supported external token
     * @param token Token address to add
     * @param rate Exchange rate (scaled by 1e18)
     * @param decimals Token decimals
     */
    function addSupportedExternalToken(address token, uint256 rate, uint8 decimals) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        require(rate > 0, "Invalid rate");

        supportedExternalTokens[token] = true;
        externalTokenRates[token] = rate;
        externalTokenDecimals[token] = decimals;

        emit ExternalTokenAdded(token, rate, decimals);
    }

    /**
     * @notice Remove supported external token
     * @param token Token address to remove
     */
    function removeSupportedExternalToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        supportedExternalTokens[token] = false;
        delete externalTokenRates[token];
        delete externalTokenDecimals[token];

        emit ExternalTokenRemoved(token);
    }

    /**
     * @notice Update exchange rate for external token
     * @param token Token address
     * @param rate New exchange rate (scaled by 1e18)
     */
    function updateExternalTokenRate(address token, uint256 rate) external onlyOwner {
        require(supportedExternalTokens[token], "Token not supported");
        require(rate > 0, "Invalid rate");

        externalTokenRates[token] = rate;
        emit ExternalTokenRateUpdated(token, rate);
    }

    /**
     * @notice Emergency withdraw function
     * @param token Token to withdraw (address(0) for HYPE)
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        if (token == address(0)) {
            // Withdraw HYPE
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert SwapFailed("HYPE withdrawal failed");
        } else {
            // Withdraw ERC20
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ==================== UUPS Upgrade ====================

    /**
     * @notice Authorize contract upgrade (UUPS pattern)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ==================== Receive Function ====================

    /**
     * @notice Receive function to accept HYPE
     */
    receive() external payable {}
}
