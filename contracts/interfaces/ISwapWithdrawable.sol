// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ISwapWithdrawable
 * @notice Opt-in interface for yield source adapters that require DEX swap for withdrawal
 * @dev Adapters that cannot withdraw natively (e.g., stHYPE staking with 0 instant liquidity)
 *      implement this alongside IYieldSourceAdapter. The Router detects support via try/catch
 *      and passes off-chain generated swap data for DEX-based withdrawal.
 */
interface ISwapWithdrawable {
    /**
     * @notice Withdraw HYPE by swapping the adapter's held tokens via DEX
     * @param hypeAmount Target HYPE value to withdraw
     * @param swapData Pre-encoded DEX swap calldata (from KyberSwap API)
     * @return hypeReceived Actual HYPE received and forwarded to caller
     */
    function instantWithdrawViaSwap(
        uint256 hypeAmount,
        bytes calldata swapData
    ) external returns (uint256 hypeReceived);
}
