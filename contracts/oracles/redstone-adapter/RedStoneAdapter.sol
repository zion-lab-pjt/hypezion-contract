// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";
import "../../interfaces/IOracleAdapter.sol";

/**
 * @title RedStoneAdapter
 * @notice Adapter for RedStone Oracle integration with HypeNova Oracle system
 * @dev Converts RedStone price feeds to HypeNova-compatible format for HyperEVM
 */
contract RedStoneAdapter is PrimaryProdDataServiceConsumerBase, IOracleAdapter {
    
    // Events
    event PriceRetrieved(string symbol, uint256 price, uint256 timestamp);
    
    // Custom errors (specific to RedStone)
    error InvalidPrice(uint256 price);
    
    /**
     * @notice Get price data from RedStone oracle
     * @param symbol Token symbol (e.g., "HYPE") 
     * @return priceData Price data in HypeNova format
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory priceData) {
        bytes32 dataFeedId = stringToBytes32(symbol);
        
        // Get price from RedStone oracle
        uint256 price = getOracleNumericValueFromTxMsg(dataFeedId);
        
        if (price == 0) {
            revert PriceNotAvailable(symbol);
        }
        
        // Return in HypeNova-compatible format
        priceData = PriceData({
            price: price,
            timestamp: block.timestamp, // RedStone provides current timestamp
            confidence: 100, // RedStone provides high confidence data
            source: OracleSource.RedStone
        });
        
        // Note: Cannot emit events in view function
        return priceData;
    }
    
    /**
     * @notice Get raw price value from RedStone
     * @param symbol Token symbol
     * @return price Raw price value
     */
    function getRawPrice(string memory symbol) external view returns (uint256 price) {
        bytes32 dataFeedId = stringToBytes32(symbol);
        price = getOracleNumericValueFromTxMsg(dataFeedId);
        
        if (price == 0) {
            revert PriceNotAvailable(symbol);
        }
        
        return price;
    }
    
    /**
     * @notice Check if RedStone price is available for a symbol
     * @param symbol Token symbol
     * @return available Whether price is available
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool available) {
        try this.getRawPrice(symbol) returns (uint256 price) {
            return price > 0;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Convert string to bytes32 for RedStone data feed ID
     * @param source String to convert
     * @return result Bytes32 representation
     */
    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }
        
        assembly {
            result := mload(add(source, 32))
        }
    }
    
    /**
     * @notice Get RedStone data service ID for debugging
     * @return Data service ID used by this adapter
     */
    function getDataServiceId() public view virtual override returns (string memory) {
        return "redstone-primary-prod";
    }
}