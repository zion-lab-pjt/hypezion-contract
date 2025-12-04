// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title OracleAggregator
 * @notice Aggregates price data from multiple oracle sources with fallback mechanism and UUPS upgradeability
 * @dev Implements weighted median calculation and automatic fallback
 */
contract OracleAggregator is AccessControlUpgradeable, IOracle, UUPSUpgradeable {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    struct OracleConfig {
        address oracle;
        uint256 weight;  // Weight for median calculation (basis points)
        bool isActive;
        uint256 maxStaleness;  // Maximum acceptable age in seconds
    }
    
    struct AggregatedPrice {
        uint256 price;
        uint256 timestamp;
        uint8 sourcesUsed;
        bool isValid;
    }
    
    // Token => Source => Config
    mapping(string => mapping(IOracle.OracleSource => OracleConfig)) public oracleConfigs;
    
    // Token => Latest aggregated price
    mapping(string => AggregatedPrice) public aggregatedPrices;
    
    // Oracle priority order for fallback
    IOracle.OracleSource[] public priorityOrder;
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_SOURCES = 1;  // Minimum number of valid sources required
    uint256 public defaultMaxStaleness; // 5 minutes default

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap;

    // Events
    event OracleConfigured(string indexed token, OracleSource indexed source, address oracle, uint256 weight);
    event PriceAggregated(string indexed token, uint256 price, uint256 timestamp, uint8 sourcesUsed);
    event OracleFallback(string indexed token, OracleSource fromSource, OracleSource toSource);
    event WeightsUpdated(string indexed token, uint256[] weights);
    
    // Errors
    error InvalidWeight();
    error InsufficientSources();
    error AllOraclesFailed();
    error OracleNotConfigured();
    error StalePrice();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // Prevent initialization of implementation contract
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during deployment through proxy
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);

        // Set default priority order
        priorityOrder.push(IOracle.OracleSource.HyperCore);
        priorityOrder.push(IOracle.OracleSource.Pyth);
        priorityOrder.push(IOracle.OracleSource.RedStone);

        defaultMaxStaleness = 300;
    }
    
    /**
     * @notice Configure an oracle source for a token
     * @param token Token symbol
     * @param source Oracle source type
     * @param oracle Oracle contract address
     * @param weight Weight for median calculation (basis points)
     * @param maxStaleness Maximum acceptable price age in seconds
     */
    function configureOracle(
        string memory token,
        OracleSource source,
        address oracle,
        uint256 weight,
        uint256 maxStaleness
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (weight > BASIS_POINTS) revert InvalidWeight();
        
        oracleConfigs[token][source] = OracleConfig({
            oracle: oracle,
            weight: weight,
            isActive: true,
            maxStaleness: maxStaleness
        });
        
        emit OracleConfigured(token, source, oracle, weight);
    }
    
    /**
     * @notice Get price data for a token (IOracle interface)
     * @param symbol Token symbol
     * @return priceData Price data struct
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory priceData) {
        AggregatedPrice memory aggregated = _aggregatePrice(symbol);
        if (!aggregated.isValid) revert AllOraclesFailed();
        
        return PriceData({
            price: aggregated.price,
            timestamp: aggregated.timestamp,
            confidence: 95, // High confidence for aggregated data
            source: OracleSource.Aggregated
        });
    }
    
    /**
     * @notice Get aggregated price for a token (legacy function)
     * @param token Token symbol
     * @return price Aggregated price
     * @return timestamp Price timestamp
     */
    function getAggregatedPrice(string memory token) external view returns (uint256 price, uint256 timestamp) {
        AggregatedPrice memory aggregated = _aggregatePrice(token);
        if (!aggregated.isValid) revert AllOraclesFailed();
        
        return (aggregated.price, aggregated.timestamp);
    }
    
    /**
     * @notice Check if price data is valid (IOracle interface)
     * @param data Price data to validate
     * @return True if price is valid and fresh
     */
    function isValidPrice(PriceData memory data) external view override returns (bool) {
        if (data.price == 0) return false;
        if (data.timestamp == 0) return false;
        if (block.timestamp - data.timestamp > defaultMaxStaleness) return false;
        return true;
    }
    
    /**
     * @notice Check if price is available for a symbol (IOracle interface)
     * @param symbol Token symbol
     * @return available Whether price is available
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool available) {
        AggregatedPrice memory aggregated = _aggregatePrice(symbol);
        return aggregated.isValid;
    }
    
    /**
     * @notice Update price from oracle sources (IOracle interface)
     * @param symbol Token symbol
     */
    function updatePrice(string memory symbol) external override onlyRole(ORACLE_ROLE) {
        AggregatedPrice memory aggregated = _aggregatePrice(symbol);
        if (!aggregated.isValid) revert AllOraclesFailed();
        
        aggregatedPrices[symbol] = aggregated;
        emit PriceUpdated(symbol, aggregated.price, aggregated.timestamp, OracleSource.Aggregated);
    }
    
    /**
     * @notice Update aggregated price for a token (legacy function)
     * @param token Token symbol
     */
    function updateAggregatedPrice(string memory token) external onlyRole(ORACLE_ROLE) {
        AggregatedPrice memory aggregated = _aggregatePrice(token);
        if (!aggregated.isValid) revert AllOraclesFailed();
        
        aggregatedPrices[token] = aggregated;
        emit PriceAggregated(token, aggregated.price, aggregated.timestamp, aggregated.sourcesUsed);
    }
    
    /**
     * @notice Internal function to aggregate prices from multiple sources
     * @param token Token symbol
     * @return aggregated Aggregated price data
     */
    function _aggregatePrice(string memory token) private view returns (AggregatedPrice memory) {
        uint256[] memory prices = new uint256[](3);
        uint256[] memory weights = new uint256[](3);
        uint256[] memory timestamps = new uint256[](3);
        uint8 validSources = 0;
        uint256 totalWeight = 0;
        
        // Try to get prices from all configured sources
        for (uint i = 0; i < priorityOrder.length; i++) {
            OracleSource source = priorityOrder[i];
            OracleConfig memory config = oracleConfigs[token][source];
            
            if (!config.isActive || config.oracle == address(0)) continue;
            
            (bool success, uint256 price, uint256 timestamp) = _getPriceFromSource(token, config);
            
            if (success && _isPriceFresh(timestamp, config.maxStaleness)) {
                prices[validSources] = price;
                weights[validSources] = config.weight;
                timestamps[validSources] = timestamp;
                totalWeight += config.weight;
                validSources++;
            }
        }
        
        if (validSources < MIN_SOURCES) {
            return AggregatedPrice(0, 0, 0, false);
        }
        
        // Calculate weighted median price
        uint256 aggregatedPrice = _calculateWeightedMedian(prices, weights, validSources, totalWeight);
        
        // Use the most recent timestamp
        uint256 latestTimestamp = timestamps[0];
        for (uint i = 1; i < validSources; i++) {
            if (timestamps[i] > latestTimestamp) {
                latestTimestamp = timestamps[i];
            }
        }
        
        return AggregatedPrice(aggregatedPrice, latestTimestamp, validSources, true);
    }
    
    /**
     * @notice Get price from a specific oracle adapter
     * @param token Token symbol
     * @param config Oracle configuration
     * @return success Whether price retrieval was successful
     * @return price Token price
     * @return timestamp Price timestamp
     */
    function _getPriceFromSource(
        string memory token,
        OracleConfig memory config
    ) private view returns (bool success, uint256 price, uint256 timestamp) {
        try IOracleAdapter(config.oracle).getPrice(token) returns (IOracleAdapter.PriceData memory priceData) {
            return (true, priceData.price, priceData.timestamp);
        } catch {
            return (false, 0, 0);
        }
    }
    
    /**
     * @notice Check if price is fresh enough
     * @param timestamp Price timestamp
     * @param maxStaleness Maximum acceptable age
     * @return isFresh Whether price is fresh
     */
    function _isPriceFresh(uint256 timestamp, uint256 maxStaleness) private view returns (bool) {
        return block.timestamp - timestamp <= maxStaleness;
    }
    
    /**
     * @notice Calculate weighted median of prices
     * @param prices Array of prices
     * @param weights Array of weights
     * @param count Number of valid prices
     * @param totalWeight Sum of all weights
     * @return median Weighted median price
     */
    function _calculateWeightedMedian(
        uint256[] memory prices,
        uint256[] memory weights,
        uint8 count,
        uint256 totalWeight
    ) private pure returns (uint256) {
        if (count == 1) return prices[0];
        
        // Sort prices and weights together
        for (uint i = 0; i < count - 1; i++) {
            for (uint j = 0; j < count - i - 1; j++) {
                if (prices[j] > prices[j + 1]) {
                    // Swap prices
                    (prices[j], prices[j + 1]) = (prices[j + 1], prices[j]);
                    // Swap weights
                    (weights[j], weights[j + 1]) = (weights[j + 1], weights[j]);
                }
            }
        }
        
        // Find weighted median
        uint256 cumulativeWeight = 0;
        uint256 medianWeight = totalWeight / 2;
        
        for (uint i = 0; i < count; i++) {
            cumulativeWeight += weights[i];
            if (cumulativeWeight >= medianWeight) {
                return prices[i];
            }
        }
        
        return prices[count - 1];
    }
    
    /**
     * @notice Set oracle priority order for fallback
     * @param newOrder Array of oracle sources in priority order
     */
    function setPriorityOrder(OracleSource[] memory newOrder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete priorityOrder;
        for (uint i = 0; i < newOrder.length; i++) {
            priorityOrder.push(newOrder[i]);
        }
    }
    
    /**
     * @notice Toggle oracle source active status
     * @param token Token symbol
     * @param source Oracle source
     * @param isActive Whether the source should be active
     */
    function setOracleActive(
        string memory token,
        OracleSource source,
        bool isActive
    ) external onlyRole(ORACLE_ROLE) {
        oracleConfigs[token][source].isActive = isActive;
    }
    
    /**
     * @notice Update weights for oracle sources
     * @param token Token symbol
     * @param sources Array of oracle sources
     * @param newWeights Array of new weights
     */
    function updateWeights(
        string memory token,
        OracleSource[] memory sources,
        uint256[] memory newWeights
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(sources.length == newWeights.length, "Length mismatch");
        
        uint256 totalWeight = 0;
        for (uint i = 0; i < sources.length; i++) {
            oracleConfigs[token][sources[i]].weight = newWeights[i];
            totalWeight += newWeights[i];
        }
        
        if (totalWeight != BASIS_POINTS) revert InvalidWeight();
        emit WeightsUpdated(token, newWeights);
    }
    
    /**
     * @notice Get oracle configuration for a token and source
     * @param token Token symbol
     * @param source Oracle source
     * @return config Oracle configuration
     */
    function getOracleConfig(
        string memory token,
        OracleSource source
    ) external view returns (OracleConfig memory) {
        return oracleConfigs[token][source];
    }
    
    /**
     * @notice Get current oracle source (IOracle interface)
     * @return Current oracle source (always Aggregated for this implementation)
     */
    function getCurrentSource() external pure override returns (OracleSource) {
        return OracleSource.Aggregated;
    }
    
    /**
     * @notice Get maximum price age (IOracle interface)
     * @return Maximum acceptable price age in seconds
     */
    function getMaxPriceAge() external view override returns (uint256) {
        return defaultMaxStaleness;
    }
    
    /**
     * @notice Check if aggregated price is valid and fresh
     * @param token Token symbol
     * @return isValid Whether the aggregated price is valid
     */
    function isAggregatedPriceValid(string memory token) external view returns (bool) {
        AggregatedPrice memory price = aggregatedPrices[token];
        return price.isValid && _isPriceFresh(price.timestamp, defaultMaxStaleness);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to DEFAULT_ADMIN_ROLE
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}