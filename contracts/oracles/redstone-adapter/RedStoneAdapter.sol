// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../interfaces/IOracleAdapter.sol";

/**
 * @title IRedStonePriceFeed
 * @notice Interface for RedStone Single Price Feed (AggregatorV3 style)
 * @dev HyperevmPriceFeedHypeWithoutRoundsV1 contract
 */
interface IRedStonePriceFeed {
    /// @notice Returns the latest price (8 decimals)
    function latestAnswer() external view returns (int256);

    /// @notice Returns decimals (should be 8)
    function decimals() external view returns (uint8);

    /// @notice Returns description
    function description() external view returns (string memory);

    /// @notice Returns the latest round data (AggregatorV3Interface style)
    /// @return roundId The round ID
    /// @return answer The price answer
    /// @return startedAt Timestamp when the round started
    /// @return updatedAt Timestamp when the round was updated
    /// @return answeredInRound The round ID in which the answer was computed
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @title RedStoneAdapter
 * @notice Oracle adapter using RedStone single price feed for HYPE token
 * @dev Uses HyperevmPriceFeedHypeWithoutRoundsV1 contract
 *      Mainnet: 0xa8a94Da411425634e3Ed6C331a32ab4fd774aa43
 *      Testnet: 0xC3346631E0A9720582fB9CAbdBEA22BC2F57741b
 */
contract RedStoneAdapter is IOracleAdapter {
    /// @notice RedStone HYPE price feed address
    address public immutable REDSTONE_HYPE_FEED;

    /// @notice RedStone uses 8 decimals
    uint8 public constant REDSTONE_DECIMALS = 8;

    /// @notice Target decimals for HypeNova (18 decimals)
    uint8 public constant TARGET_DECIMALS = 18;

    /// @notice Multiplier to convert from 8 to 18 decimals
    uint256 public constant DECIMAL_MULTIPLIER = 10 ** (TARGET_DECIMALS - REDSTONE_DECIMALS);

    /// @param _priceFeed RedStone HYPE price feed address
    constructor(address _priceFeed) {
        require(_priceFeed != address(0), "Invalid price feed address");
        REDSTONE_HYPE_FEED = _priceFeed;
    }

    /**
     * @notice Get price for a token symbol
     * @param symbol Token symbol (only "HYPE" supported)
     * @return priceData Structured price data with 18 decimals
     */
    function getPrice(string memory symbol) external view override returns (PriceData memory priceData) {
        require(_isHype(symbol), "Only HYPE supported");

        IRedStonePriceFeed feed = IRedStonePriceFeed(REDSTONE_HYPE_FEED);

        // Use latestRoundData for both price and timestamp
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        require(answer > 0, "Invalid price");

        // Convert from 8 to 18 decimals
        uint256 normalizedPrice = uint256(answer) * DECIMAL_MULTIPLIER;

        priceData = PriceData({
            price: normalizedPrice,
            timestamp: updatedAt,
            confidence: 95,
            source: OracleSource.RedStone
        });

        return priceData;
    }

    /**
     * @notice Get raw price in 8 decimals
     * @param symbol Token symbol (only "HYPE" supported)
     * @return Raw price with 8 decimals
     */
    function getRawPrice(string memory symbol) external view returns (uint256) {
        require(_isHype(symbol), "Only HYPE supported");

        int256 answer = IRedStonePriceFeed(REDSTONE_HYPE_FEED).latestAnswer();
        require(answer > 0, "Invalid price");

        return uint256(answer);
    }

    /**
     * @notice Check if price is available
     * @param symbol Token symbol
     * @return True if price is available
     */
    function isPriceAvailable(string memory symbol) external view override returns (bool) {
        if (!_isHype(symbol)) return false;

        try IRedStonePriceFeed(REDSTONE_HYPE_FEED).latestAnswer() returns (int256 answer) {
            return answer > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Get feed info
     * @return feedDecimals Feed decimals
     * @return feedDescription Feed description
     */
    function getFeedInfo() external view returns (uint8 feedDecimals, string memory feedDescription) {
        IRedStonePriceFeed feed = IRedStonePriceFeed(REDSTONE_HYPE_FEED);
        return (feed.decimals(), feed.description());
    }

    /**
     * @notice Check if symbol is HYPE (case-insensitive)
     */
    function _isHype(string memory symbol) internal pure returns (bool) {
        bytes32 symbolHash = keccak256(abi.encodePacked(symbol));
        return symbolHash == keccak256("HYPE") || symbolHash == keccak256("hype");
    }
}
