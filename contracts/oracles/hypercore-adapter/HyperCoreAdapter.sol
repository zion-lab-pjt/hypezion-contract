// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../interfaces/IOracleAdapter.sol";
/**
 * @title HyperCoreAdapter
 * @notice Adapter for HyperCore Precompile integration
 * @dev Provides access to native HyperEVM price data from L1 trading engine
 *      Based on QuickNode documentation - uses correct token indexes
 */
contract HyperCoreAdapter is IOracleAdapter {

    // HyperCore precompile addresses
    address constant ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;
    address constant PERP_ASSET_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080a;

    // Token configuration struct
    struct TokenConfig {
        uint32 index;       // Token index in oracle precompile
        uint8 szDecimals;   // Price decimals for conversion
        bool isActive;      // Whether token is configured
    }

    // Token symbol to configuration mapping
    mapping(string => TokenConfig) public tokenConfigs;

    // Events
    event PriceRetrieved(string symbol, uint256 price, uint32 index);
    event TokenConfigured(string symbol, uint32 index, uint8 szDecimals);

    // Custom errors
    error TokenNotConfigured(string symbol);
    error InvalidTokenConfig(uint32 index, uint8 szDecimals);

    constructor() {
        // Default initialization - will be configured via initializeForNetwork()
    }

    /**
     * @notice Configure a token with index and decimals
     * @param symbol Token symbol (e.g., "HYPE", "BTC")
     * @param index Token index in oracle precompile
     * @param szDecimals Number of significant digits for price conversion
     */
    function configureToken(string memory symbol, uint32 index, uint8 szDecimals) external {
        tokenConfigs[symbol] = TokenConfig({
            index: index,
            szDecimals: szDecimals,
            isActive: true
        });

        emit TokenConfigured(symbol, index, szDecimals);
    }

    /**
     * @notice Configure multiple tokens at once
     * @param symbols Array of token symbols
     * @param indexes Array of token indexes
     * @param szDecimalsArray Array of szDecimals
     */
    function configureTokens(
        string[] memory symbols,
        uint32[] memory indexes,
        uint8[] memory szDecimalsArray
    ) external {
        require(symbols.length == indexes.length && indexes.length == szDecimalsArray.length, "Array length mismatch");

        for (uint i = 0; i < symbols.length; i++) {
            tokenConfigs[symbols[i]] = TokenConfig({
                index: indexes[i],
                szDecimals: szDecimalsArray[i],
                isActive: true
            });

            emit TokenConfigured(symbols[i], indexes[i], szDecimalsArray[i]);
        }
    }
    
    /**
     * @notice Get price data from HyperCore following QuickNode documentation pattern
     * @param symbol Token symbol (e.g., "BTC", "ETH", "HYPE")
     * @return priceData Price data in HypeNova format
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory priceData) {
        TokenConfig memory config = tokenConfigs[symbol];

        if (!config.isActive) {
            revert TokenNotConfigured(symbol);
        }

        // Get raw oracle price using direct precompile call
        bool success;
        bytes memory result;
        (success, result) = ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(config.index));
        require(success, "OraclePx precompile call failed");
        uint64 rawPrice = abi.decode(result, (uint64));

        // Convert price using configured szDecimals
        uint256 divisor = 10 ** (6 - config.szDecimals);
        uint256 convertedPrice = (uint256(rawPrice) * 1e18) / divisor;

        // Return in HypeNova-compatible format
        priceData = PriceData({
            price: convertedPrice,
            timestamp: block.timestamp,
            confidence: 100,
            source: OracleSource.HyperCore
        });

        return priceData;
    }
    
    /**
     * @notice Get raw price from oracle precompile using L1Read
     * @param symbol Token symbol
     * @return price Raw price value as uint64
     */
    function getRawPrice(string memory symbol) external view returns (uint64 price) {
        TokenConfig memory config = tokenConfigs[symbol];

        if (!config.isActive) {
            revert TokenNotConfigured(symbol);
        }

        bool success;
        bytes memory result;
        (success, result) = ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(config.index));
        require(success, "OraclePx precompile call failed");
        return abi.decode(result, (uint64));
    }
    
    /**
     * @notice Check if oracle precompile is available by testing with SOL (index 0)
     * @return available Whether precompile is functional
     */
    function isPrecompileAvailable() public view returns (bool available) {
        try this.getRawPrice("SOL") returns (uint64 price) {
            return price > 0;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Check if price is available for a symbol
     * @param symbol Token symbol
     * @return available Whether price is available from precompile
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool available) {
        TokenConfig memory config = tokenConfigs[symbol];

        if (!config.isActive) {
            return false;
        }

        try this.getRawPrice(symbol) returns (uint64 price) {
            return price > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Get token configuration
     * @param symbol Token symbol
     * @return config Token configuration struct
     */
    function getTokenConfig(string memory symbol) external view returns (TokenConfig memory config) {
        return tokenConfigs[symbol];
    }

    // Debug functions removed to reduce contract size
}