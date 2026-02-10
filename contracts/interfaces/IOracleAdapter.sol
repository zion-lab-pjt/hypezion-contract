// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IOracleAdapter
 * @notice Standard interface for all oracle adapters in HypeNova
 * @dev All oracle adapters (RedStone, HyperCore, HyperLend) must implement this interface
 */
interface IOracleAdapter {
    struct PriceData {
        uint256 price;      // Price in USD with 18 decimals (e.g., 50e18 = $50)
        uint256 timestamp;  // Unix timestamp when price was updated
        uint256 confidence; // Confidence score 0-100 (100 = highest confidence)
        OracleSource source; // Source of the price data
    }

    enum OracleSource {
        HyperCore,   // Native HyperEVM precompile
        Pyth,        // Pyth Network oracle
        RedStone,    // RedStone oracle
        Chainlink,   // Chainlink oracle
        Manual,      // Manual price updates
        Aggregated   // Multi-source aggregated price
    }

    // Events
    event PriceRetrieved(string indexed symbol, uint256 price, uint256 timestamp, OracleSource source);

    // Custom errors
    error PriceNotAvailable(string symbol);
    error InvalidSymbol(string symbol);
    error SourceUnavailable();

    // Core functions that all adapters must implement
    function getPrice(string memory symbol) external view returns (PriceData memory);
    function isPriceAvailable(string memory symbol) external view returns (bool);
}
