// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HzUSD
 * @notice ERC20 stablecoin token for HypeZion Protocol on HyperEVM
 * @dev Only the designated exchange contract can mint and burn tokens
 */
contract HzUSD is ERC20, Ownable {
    address public exchange;

    // Events
    event ExchangeSet(address indexed newExchange);

    // Custom errors
    error UnauthorizedMinter(address caller);
    error ZeroAddress();

    constructor() ERC20("HypeZion USD", "hzUSD") Ownable(msg.sender) {}

    /**
     * @notice Set the exchange contract address
     * @param _exchange Address of the HypeZionExchange contract
     */
    function setExchange(address _exchange) external onlyOwner {
        if (_exchange == address(0)) revert ZeroAddress();
        exchange = _exchange;
        emit ExchangeSet(_exchange);
    }

    /**
     * @notice Mint new hzUSD tokens
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != exchange) revert UnauthorizedMinter(msg.sender);
        _mint(to, amount);
    }

    /**
     * @notice Burn hzUSD tokens
     * @param from Address from which to burn tokens
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        if (msg.sender != exchange) revert UnauthorizedMinter(msg.sender);
        _burn(from, amount);
    }
}