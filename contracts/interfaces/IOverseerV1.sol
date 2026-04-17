// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IOverseerV1
 * @notice Interface for Valantis stHYPE OverseerV1 contract
 * @dev Used by StHYPEStakingAdapter for minting/burning stHYPE
 *
 * Mainnet: 0xB96f07367e69e86d6e9C3F29215885104813eeAE
 * Testnet: 0x371de8EBDA2ebB627a4f6d92bD6d01eC385A309b
 */
interface IOverseerV1 {
    /// @notice Mint stHYPE by sending HYPE as msg.value
    /// @param to Recipient of stHYPE tokens
    /// @return amount stHYPE minted (1:1 with HYPE sent)
    function mint(address to) external payable returns (uint256 amount);

    /// @notice Burn stHYPE and redeem HYPE instantly if liquidity available
    /// @param to Recipient of HYPE
    /// @param amount stHYPE amount to burn
    /// @param communityCode Community code string
    /// @return burnID ID for claiming remaining queued portion (if any)
    function burnAndRedeemIfPossible(
        address to,
        uint256 amount,
        string calldata communityCode
    ) external returns (uint256 burnID);

    /// @notice Claim a previously queued burn
    /// @param burnID ID returned by burnAndRedeemIfPossible
    function redeem(uint256 burnID) external;

    /// @notice Amount of HYPE available for instant redemption
    function maxRedeemable() external view returns (uint256);

    /// @notice Check if a queued burn is ready to claim
    function redeemable(uint256 burnID) external view returns (bool);
}
