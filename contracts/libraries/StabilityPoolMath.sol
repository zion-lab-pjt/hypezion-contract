// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library StabilityPoolMath {
    uint256 private constant PRECISION = 1e18;

    /// @notice Calculate stability pool cap: hzusd_nav * hzusd_in_pool + hzhype_nav * hzhype_in_pool
    /// @param hzusdNav NAV of HzUSD in HYPE terms (1e18 scaled)
    /// @param hzusdInPool Amount of HzUSD in the pool
    /// @param hzhypeNav NAV of hzHYPE in HYPE terms (1e18 scaled)
    /// @param hzhypeInPool Amount of hzHYPE in the pool
    /// @return totalPoolValue Total value of pool in HYPE terms (1e18 scaled)
    function stabilityPoolCap(
        uint256 hzusdNav,
        uint256 hzusdInPool,
        uint256 hzhypeNav,
        uint256 hzhypeInPool
    ) internal pure returns (uint256 totalPoolValue) {
        uint256 hzusdCap = (hzusdNav * hzusdInPool) / PRECISION;
        uint256 hzhypeCap = (hzhypeNav * hzhypeInPool) / PRECISION;
        totalPoolValue = hzusdCap + hzhypeCap;
    }

    /// @notice Calculate staked hzUSD token NAV: stability_pool_cap / shzusd_supply
    /// @param hzusdNav NAV of HzUSD in HYPE terms (1e18 scaled)
    /// @param hzusdInPool Amount of HzUSD in the pool
    /// @param hzhypeNav NAV of hzHYPE in HYPE terms (1e18 scaled)
    /// @param hzhypeInPool Amount of hzHYPE in the pool
    /// @param shzusdSupply Total supply of staked HzUSD tokens
    /// @return nav NAV of one staked HzUSD token in HYPE terms (1e18 scaled)
    function shzusdNav(
        uint256 hzusdNav,
        uint256 hzusdInPool,
        uint256 hzhypeNav,
        uint256 hzhypeInPool,
        uint256 shzusdSupply
    ) internal pure returns (uint256 nav) {
        if (shzusdSupply == 0) {
            return PRECISION; // 1:1 when empty
        }

        uint256 totalCap = stabilityPoolCap(
            hzusdNav,
            hzusdInPool,
            hzhypeNav,
            hzhypeInPool
        );

        nav = (totalCap * PRECISION) / shzusdSupply;
    }

    /// @notice Calculate proportional withdrawal: user_shzusd_tokens * pool_amount / total_shzusd_tokens
    /// @param userShzusdAmount Amount of staked HzUSD tokens user is withdrawing
    /// @param totalShzusdSupply Total supply of staked HzUSD tokens
    /// @param poolAmount Total amount of the specific asset in the pool
    /// @return amountToWithdraw Proportional amount of the asset the user receives
    function amountTokenToWithdraw(
        uint256 userShzusdAmount,
        uint256 totalShzusdSupply,
        uint256 poolAmount
    ) internal pure returns (uint256 amountToWithdraw) {
        if (totalShzusdSupply == 0) {
            return 0;
        }

        amountToWithdraw = (userShzusdAmount * poolAmount) / totalShzusdSupply;
    }
}