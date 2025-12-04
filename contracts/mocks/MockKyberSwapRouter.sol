// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMetaAggregationRouterV2.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "./MockKHYPE.sol";

/**
 * @title MockKyberSwapRouter
 * @notice Mock implementation of KyberSwap MetaAggregationRouterV2 for testnet
 * @dev Frontend calls real KyberSwap API to get routes and encoded swap data,
 *      but this mock contract executes swaps using Kinetiq exchange rate instead.
 *
 * Architecture:
 * - Frontend: Calls KyberSwap API normally (gets routes, builds swap data)
 * - DexIntegration: Calls this router with encoded data (same as mainnet)
 * - This contract: Decodes params, swaps using Kinetiq rate (1:1 approximately)
 *
 * Supported swaps:
 * - mkHYPE → HYPE (redemption flow)
 * - HYPE → mkHYPE (for testing)
 */
contract MockKyberSwapRouter is IMetaAggregationRouterV2 {
    using SafeERC20 for IERC20;

    // ==================== State Variables ====================

    IKinetiqIntegration public kinetiqIntegration;
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ==================== Errors ====================

    error InvalidTokenPair(address srcToken, address dstToken);
    error InsufficientReturnAmount(uint256 returnAmount, uint256 minReturnAmount);
    error SwapFailed(string reason);
    error ZeroAddress();

    // ==================== Events ====================

    event KinetiqIntegrationUpdated(address indexed newKinetiqIntegration);

    // ==================== Constructor ====================

    constructor(address _kinetiqIntegration) {
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

        if (!isMkHYPEtoHYPE && !isHYPEtoMkHYPE) {
            revert InvalidTokenPair(srcToken, dstToken);
        }

        // For ERC20: Use actual allowance if available (for integration with DexIntegration)
        // For native: always use desc.amount
        uint256 amountIn;
        if (srcToken != NATIVE_TOKEN) {
            uint256 allowance = IERC20(srcToken).allowance(msg.sender, address(this));
            amountIn = allowance > 0 ? allowance : desc.amount;
        } else {
            amountIn = desc.amount;
        }

        // Get exchange rate from Kinetiq
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
        uint256 PRECISION = 1e18;

        // Calculate output amount based on Kinetiq rate
        if (isMkHYPEtoHYPE) {
            // mkHYPE → HYPE: amountOut = amountIn * exchangeRate / PRECISION
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

        } else {
            // HYPE → mkHYPE: amountOut = amountIn * PRECISION / exchangeRate
            returnAmount = (amountIn * PRECISION) / exchangeRate;

            // Verify msg.value matches amountIn
            if (msg.value != amountIn) revert SwapFailed("Incorrect HYPE amount");

            // Mint mkHYPE to recipient
            // Note: This contract must be added as minter via MockKHYPE.addMinter()
            MockKHYPE(mkHYPE).mint(desc.dstReceiver, returnAmount);
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
    function setKinetiqIntegration(address _kinetiqIntegration) external {
        if (_kinetiqIntegration == address(0)) revert ZeroAddress();
        kinetiqIntegration = IKinetiqIntegration(_kinetiqIntegration);
        emit KinetiqIntegrationUpdated(_kinetiqIntegration);
    }

    /**
     * @notice Receive function to accept HYPE
     */
    receive() external payable {}

    /**
     * @notice Emergency withdraw function
     * @param token Token to withdraw (address(0) for HYPE)
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external {
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
}
