// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IOracle
 * @notice Generic oracle interface for price data across HypeNova protocol
 * @dev Provides standardized price data access for any oracle implementation
 */
interface IOracle {
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
    event PriceUpdated(string indexed symbol, uint256 price, uint256 timestamp, OracleSource source);
    event OracleFallback(OracleSource from, OracleSource to, string reason);
    event PriceStale(string indexed symbol, uint256 lastUpdate, uint256 maxAge);

    // Custom errors
    error OraclePriceStale(uint256 timestamp, uint256 maxAge);
    error OracleUnavailable();
    error InvalidPrice(uint256 price);
    error PriceNotFound(string symbol);

    // Core functions
    function getPrice(string memory symbol) external view returns (PriceData memory);
    function updatePrice(string memory symbol) external;

    // Validation functions
    function isValidPrice(PriceData memory data) external view returns (bool);
    function isPriceAvailable(string memory symbol) external view returns (bool);

    // View functions
    function getCurrentSource() external view returns (OracleSource);
    function getMaxPriceAge() external view returns (uint256);
}
