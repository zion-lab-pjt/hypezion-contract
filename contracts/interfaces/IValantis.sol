// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IValantis
 * @notice Interfaces for Valantis STEX AMM pool integration on HyperEVM
 */

interface ISTEXAMM {
    function withdrawalModule() external view returns (address);

    function deposit(
        uint256 _amount,
        uint256 _minShares,
        uint256 _deadline,
        address _recipient
    ) external returns (uint256 shares);

    function withdraw(
        uint256 _shares,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint256 _deadline,
        address _recipient,
        bool _unwrapToNativeToken,
        bool _isInstantWithdrawal
    ) external returns (uint256 amount0, uint256 amount1);

    function getAmountOut(
        address _tokenIn,
        uint256 _amountIn,
        bool _isInstantWithdraw
    ) external view returns (uint256 amountOut);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISovereignPool {
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1);
}

interface IValantisWithdrawalModule {
    function claim(uint256 _idLPQueue) external;
    function amountToken0PendingUnstaking() external view returns (uint256);
    function amountToken1PendingLPWithdrawal() external view returns (uint256);
    function amountToken1LendingPool() external view returns (uint256);
    function nextWithdrawalId() external view returns (uint256);
}

interface IWHYPE {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IStakingAccountant {
    function kHYPEToHYPE(uint256 amount) external view returns (uint256);
    function HYPEToKHYPE(uint256 amount) external view returns (uint256);
}
