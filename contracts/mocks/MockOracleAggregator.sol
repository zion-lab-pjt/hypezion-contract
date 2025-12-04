// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IOracle.sol";

/**
 * @title MockOracleAggregator
 * @notice Mock oracle for testing - implements IOracle interface with manual price updates
 * @dev Use this for testing contracts that depend on IOracle (e.g., HypeZionExchange)
 */
contract MockOracleAggregator is IOracle, AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 300; // 5 minutes

    // State variables
    mapping(string => PriceData) public prices;
    uint256 public maxPriceAge = DEFAULT_MAX_PRICE_AGE;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    /**
     * @notice Get price data for a symbol
     * @param symbol Token symbol (e.g., "HYPE")
     * @return PriceData struct with price, timestamp, confidence, and source
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory) {
        return prices[symbol];
    }

    /**
     * @notice Update price (no-op in mock, use setPrice instead)
     * @param symbol Token symbol
     */
    function updatePrice(string memory symbol) external override onlyRole(ORACLE_ROLE) {
        // No-op - prices are set manually via setPrice
        emit PriceUpdated(symbol, prices[symbol].price, prices[symbol].timestamp, prices[symbol].source);
    }

    /**
     * @notice Check if price data is valid (not stale)
     * @param data Price data to validate
     * @return True if price is fresh enough
     */
    function isValidPrice(PriceData memory data) external view override returns (bool) {
        if (data.price == 0) return false;
        if (data.timestamp == 0) return false;
        if (block.timestamp - data.timestamp > maxPriceAge) return false;
        return true;
    }

    /**
     * @notice Check if price is available for a symbol
     * @param symbol Token symbol
     * @return available Whether price is available
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool available) {
        PriceData memory data = prices[symbol];
        if (data.price == 0) return false;
        if (data.timestamp == 0) return false;
        if (block.timestamp - data.timestamp > maxPriceAge) return false;
        return true;
    }

    /**
     * @notice Get current oracle source
     * @return Current OracleSource (always Aggregated for mock)
     */
    function getCurrentSource() external pure override returns (OracleSource) {
        return OracleSource.Aggregated;
    }

    /**
     * @notice Get maximum allowed price age
     * @return Max age in seconds
     */
    function getMaxPriceAge() external view override returns (uint256) {
        return maxPriceAge;
    }

    // ============ Mock Functions ============

    /**
     * @notice Manually update price for a symbol (backward compatible with old tests)
     * @param symbol Token symbol
     * @param price Price value (18 decimals)
     * @param timestamp Price timestamp
     */
    function updatePriceManual(
        string memory symbol,
        uint256 price,
        uint256 timestamp
    ) external onlyRole(ORACLE_ROLE) {
        prices[symbol] = PriceData({
            price: price,
            timestamp: timestamp,
            confidence: 100,
            source: OracleSource.Aggregated
        });

        emit PriceUpdated(symbol, price, timestamp, OracleSource.Aggregated);
    }

    /**
     * @notice Set price with custom source (for testing source-specific behavior)
     * @param symbol Token symbol
     * @param price Price value (18 decimals)
     * @param timestamp Price timestamp
     * @param source Oracle source to report
     */
    function updatePriceWithSource(
        string memory symbol,
        uint256 price,
        uint256 timestamp,
        OracleSource source
    ) external onlyRole(ORACLE_ROLE) {
        prices[symbol] = PriceData({
            price: price,
            timestamp: timestamp,
            confidence: 100,
            source: source
        });

        emit PriceUpdated(symbol, price, timestamp, source);
    }

    /**
     * @notice Set maximum price age
     * @param _maxAge New max age in seconds
     */
    function setMaxPriceAge(uint256 _maxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPriceAge = _maxAge;
    }

    /**
     * @notice Validate price and revert if invalid
     * @param symbol Token symbol to validate
     */
    function validatePrice(string memory symbol) external view {
        PriceData memory data = prices[symbol];

        if (data.price == 0) {
            revert InvalidPrice(data.price);
        }

        if (block.timestamp - data.timestamp > maxPriceAge) {
            revert OraclePriceStale(data.timestamp, maxPriceAge);
        }
    }
}
