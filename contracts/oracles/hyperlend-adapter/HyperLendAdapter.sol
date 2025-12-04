// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../interfaces/IOracleAdapter.sol";

/**
 * @notice Interface for HyperLend Oracle (Chainlink-compatible)
 */
interface IHyperLendOracle {
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
    function latestRound() external view returns (uint256);
    function getRoundData(uint256 roundId) external view returns (
        uint256 roundId_,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint256 answeredInRound
    );
}

/**
 * @title HyperLendAdapter
 * @notice Adapter for HyperLend Oracle integration
 * @dev Converts HyperLend Chainlink-compatible format to HypeNova format
 */
contract HyperLendAdapter is IOracleAdapter {
    
    // HyperLend oracle addresses for different tokens
    mapping(string => address) public hyperLendOracles;
    
    // Events
    event PriceRetrieved(string symbol, uint256 price, uint256 timestamp);
    event OracleConfigured(string symbol, address oracle);
    
    // Custom errors (specific to HyperLend)
    error OracleNotConfigured(string symbol);
    error InvalidPrice(int256 price);
    error StalePrice(uint256 timestamp);
    
    /**
     * @notice Configure HyperLend oracle address for a token
     * @param symbol Token symbol (e.g., "HYPE")
     * @param oracleAddress HyperLend oracle contract address
     */
    function configureOracle(string memory symbol, address oracleAddress) external {
        hyperLendOracles[symbol] = oracleAddress;
        emit OracleConfigured(symbol, oracleAddress);
    }
    
    /**
     * @notice Get price data from HyperLend oracle
     * @param symbol Token symbol
     * @return priceData Price data in HypeNova format
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory priceData) {
        address oracleAddress = hyperLendOracles[symbol];
        if (oracleAddress == address(0)) {
            revert OracleNotConfigured(symbol);
        }
        
        IHyperLendOracle oracle = IHyperLendOracle(oracleAddress);
        
        // Get latest price data
        int256 answer = oracle.latestAnswer();
        uint256 timestamp = oracle.latestTimestamp();
        
        if (answer <= 0) {
            revert InvalidPrice(answer);
        }
        
        uint256 price = uint256(answer);
        
        // Return in HypeNova-compatible format
        priceData = PriceData({
            price: price,
            timestamp: timestamp,
            confidence: 95, // HyperLend provides high confidence
            source: OracleSource.Chainlink // Use Chainlink as source type
        });
        
        // Note: Cannot emit events in view function
        return priceData;
    }
    
    /**
     * @notice Get raw price value from HyperLend oracle
     * @param symbol Token symbol
     * @return price Raw price value
     * @return timestamp Price timestamp
     */
    function getRawPrice(string memory symbol) external view returns (uint256 price, uint256 timestamp) {
        address oracleAddress = hyperLendOracles[symbol];
        if (oracleAddress == address(0)) {
            revert OracleNotConfigured(symbol);
        }
        
        IHyperLendOracle oracle = IHyperLendOracle(oracleAddress);
        
        int256 answer = oracle.latestAnswer();
        timestamp = oracle.latestTimestamp();
        
        if (answer <= 0) {
            revert InvalidPrice(answer);
        }
        
        return (uint256(answer), timestamp);
    }
    
    /**
     * @notice Check if price is available for a symbol
     * @param symbol Token symbol
     * @return available Whether price is available
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool available) {
        address oracleAddress = hyperLendOracles[symbol];
        if (oracleAddress == address(0)) {
            return false;
        }
        
        try this.getRawPrice(symbol) returns (uint256 price, uint256) {
            return price > 0;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Get historical price data from specific round
     * @param symbol Token symbol
     * @param roundId Round ID to query
     * @return priceData Historical price data
     */
    function getHistoricalPrice(
        string memory symbol, 
        uint256 roundId
    ) external view returns (PriceData memory priceData) {
        address oracleAddress = hyperLendOracles[symbol];
        if (oracleAddress == address(0)) {
            revert OracleNotConfigured(symbol);
        }
        
        IHyperLendOracle oracle = IHyperLendOracle(oracleAddress);
        
        (,int256 answer, uint256 startedAt, uint256 updatedAt,) = oracle.getRoundData(roundId);
        
        if (answer <= 0) {
            revert InvalidPrice(answer);
        }
        
        priceData = PriceData({
            price: uint256(answer),
            timestamp: updatedAt > 0 ? updatedAt : startedAt,
            confidence: 95,
            source: OracleSource.Chainlink
        });
        
        return priceData;
    }
    
    /**
     * @notice Get configured oracle address for a token
     * @param symbol Token symbol
     * @return oracle Oracle contract address
     */
    function getOracleAddress(string memory symbol) external view returns (address oracle) {
        return hyperLendOracles[symbol];
    }
    
    /**
     * @notice Check if oracle is configured for a token
     * @param symbol Token symbol
     * @return configured Whether oracle is configured
     */
    function isOracleConfigured(string memory symbol) external view returns (bool configured) {
        return hyperLendOracles[symbol] != address(0);
    }
}