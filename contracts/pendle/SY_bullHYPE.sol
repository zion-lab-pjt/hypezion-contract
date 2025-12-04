// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../external/pendle/interfaces/IStandardizedYield.sol";
import "../external/pendle/core/erc20/PendleERC20.sol";
import "../external/pendle/core/libraries/math/PMath.sol";
import "../external/pendle/core/libraries/TokenHelper.sol";
import "../external/pendle/core/libraries/Errors.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SY_bullHYPE
 * @notice StandardizedYield wrapper for bullHYPE (leveraged token)
 * @dev Fixed 1:1 exchange rate - points-only speculation market
 *
 * DESIGN RATIONALE:
 * This contract wraps bullHYPE (non-yield-bearing leveraged token) for Pendle integration.
 * Unlike tokens with dynamic yield, this maintains a fixed 1:1 exchange rate.
 *
 * 1. **No Yield**: bullHYPE does not generate on-chain yield, so exchangeRate() = 1.0 always
 *
 * 2. **Points Market**: Users deposit bullHYPE to get PT/YT tokens. YT holders speculate
 *    on HypeZion points value (tracked off-chain via Pendle's balance fetcher)
 *
 * 3. **Single Token**: Only accepts bullHYPE (no dual-token support needed)
 *
 * 4. **1:1 Conversion**: Deposit 100 bullHYPE → get 100 SY-bullHYPE, redeem 100 SY → get 100 bullHYPE
 *
 * Reference:
 * - Pendle points markets: Used by Ethena, EtherFi, Eigenlayer for point speculation
 * - Off-chain tracking: Points calculated via Pendle balance fetcher, stored on-chain
 *
 * @custom:security-contact security@hypezion.com
 */
contract SY_bullHYPE is IStandardizedYield, PendleERC20, TokenHelper, Ownable, Pausable {
    using PMath for uint256;

    address public immutable yieldToken;  // bullHYPE (ERC20 leveraged token)

    constructor(
        string memory _name,
        string memory _symbol,
        address _bullHYPE
    ) PendleERC20(_name, _symbol, IERC20Metadata(_bullHYPE).decimals()) Ownable(msg.sender) {
        yieldToken = _bullHYPE;
    }

    // solhint-disable no-empty-blocks
    receive() external payable {}

    /*///////////////////////////////////////////////////////////////
                    DEPOSIT/REDEEM USING BASE TOKENS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IStandardizedYield-deposit}
     */
    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut
    ) external payable nonReentrant returns (uint256 amountSharesOut) {
        if (!isValidTokenIn(tokenIn)) revert Errors.SYInvalidTokenIn(tokenIn);
        if (amountTokenToDeposit == 0) revert Errors.SYZeroDeposit();

        _transferIn(tokenIn, msg.sender, amountTokenToDeposit);

        amountSharesOut = _deposit(tokenIn, amountTokenToDeposit);
        if (amountSharesOut < minSharesOut) revert Errors.SYInsufficientSharesOut(amountSharesOut, minSharesOut);

        _mint(receiver, amountSharesOut);
        emit Deposit(msg.sender, receiver, tokenIn, amountTokenToDeposit, amountSharesOut);
    }

    /**
     * @dev See {IStandardizedYield-redeem}
     */
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external nonReentrant returns (uint256 amountTokenOut) {
        if (!isValidTokenOut(tokenOut)) revert Errors.SYInvalidTokenOut(tokenOut);
        if (amountSharesToRedeem == 0) revert Errors.SYZeroRedeem();

        if (burnFromInternalBalance) {
            _burn(address(this), amountSharesToRedeem);
        } else {
            _burn(msg.sender, amountSharesToRedeem);
        }

        amountTokenOut = _redeem(receiver, tokenOut, amountSharesToRedeem);
        if (amountTokenOut < minTokenOut) revert Errors.SYInsufficientTokenOut(amountTokenOut, minTokenOut);
        emit Redeem(msg.sender, receiver, tokenOut, amountSharesToRedeem, amountTokenOut);
    }

    /// @notice Get exchange rate (always 1.0 for non-yield token)
    /// @return Exchange rate in 1e18 precision (always 1.0)
    /// @dev Fixed 1:1 exchange rate. Points are tracked off-chain via Pendle's balance fetcher.
    function exchangeRate() public pure virtual override returns (uint256) {
        return PMath.ONE;  // Always 1.0 (1e18)
    }

    /// @notice Internal deposit function (1:1 conversion)
    function _deposit(
        address /*tokenIn*/,
        uint256 amountDeposited
    ) internal virtual returns (uint256 amountSharesOut) {
        // bullHYPE deposits convert 1:1 to SY shares
        amountSharesOut = amountDeposited;
    }

    /// @notice Internal redeem function (1:1 conversion)
    function _redeem(
        address receiver,
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal virtual returns (uint256 amountTokenOut) {
        // SY shares redeem 1:1 to bullHYPE
        amountTokenOut = amountSharesToRedeem;
        _transferOut(yieldToken, receiver, amountTokenOut);
    }

    /// @notice Preview deposit amount (1:1)
    function _previewDeposit(
        address /*tokenIn*/,
        uint256 amountTokenToDeposit
    ) internal pure virtual returns (uint256 amountSharesOut) {
        return amountTokenToDeposit;
    }

    /// @notice Preview redeem amount (1:1)
    function _previewRedeem(
        address /*tokenOut*/,
        uint256 amountSharesToRedeem
    ) internal pure virtual returns (uint256 amountTokenOut) {
        return amountSharesToRedeem;
    }

    /// @notice Get accepted input tokens (only bullHYPE)
    function getTokensIn() public view virtual override returns (address[] memory res) {
        res = new address[](1);
        res[0] = yieldToken;  // bullHYPE
    }

    /// @notice Get accepted output tokens (only bullHYPE)
    function getTokensOut() public view virtual override returns (address[] memory res) {
        res = new address[](1);
        res[0] = yieldToken;  // bullHYPE
    }

    /// @notice Check if token is valid input
    function isValidTokenIn(address token) public view virtual override returns (bool) {
        return token == yieldToken;
    }

    /// @notice Check if token is valid output
    function isValidTokenOut(address token) public view virtual override returns (bool) {
        return token == yieldToken;
    }

    /// @notice Get asset info for Pendle integration
    /// @dev Returns bullHYPE as the asset (same as yieldToken for non-vault tokens)
    function assetInfo()
        external
        view
        virtual
        returns (AssetType assetType, address assetAddress, uint8 assetDecimals)
    {
        return (AssetType.TOKEN, yieldToken, IERC20Metadata(yieldToken).decimals());
    }

    /*///////////////////////////////////////////////////////////////
                           REWARDS-RELATED
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {IStandardizedYield-claimRewards}
     */
    function claimRewards(address /*user*/) external virtual override returns (uint256[] memory rewardAmounts) {
        rewardAmounts = new uint256[](0);
    }

    /**
     * @dev See {IStandardizedYield-getRewardTokens}
     */
    function getRewardTokens() external view virtual override returns (address[] memory rewardTokens) {
        rewardTokens = new address[](0);
    }

    /**
     * @dev See {IStandardizedYield-accruedRewards}
     */
    function accruedRewards(address /*user*/) external view virtual override returns (uint256[] memory rewardAmounts) {
        rewardAmounts = new uint256[](0);
    }

    function rewardIndexesCurrent() external virtual override returns (uint256[] memory indexes) {
        indexes = new uint256[](0);
    }

    function rewardIndexesStored() external view virtual override returns (uint256[] memory indexes) {
        indexes = new uint256[](0);
    }

    /*///////////////////////////////////////////////////////////////
                        PREVIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function previewDeposit(
        address tokenIn,
        uint256 amountTokenToDeposit
    ) external view virtual returns (uint256 amountSharesOut) {
        if (!isValidTokenIn(tokenIn)) revert Errors.SYInvalidTokenIn(tokenIn);
        return _previewDeposit(tokenIn, amountTokenToDeposit);
    }

    function previewRedeem(
        address tokenOut,
        uint256 amountSharesToRedeem
    ) external view virtual returns (uint256 amountTokenOut) {
        if (!isValidTokenOut(tokenOut)) revert Errors.SYInvalidTokenOut(tokenOut);
        return _previewRedeem(tokenOut, amountSharesToRedeem);
    }

    /*///////////////////////////////////////////////////////////////
                        PAUSE FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _beforeTokenTransfer(address, address, uint256) internal virtual override whenNotPaused {}

    /*///////////////////////////////////////////////////////////////
                        PRICING INFO
    //////////////////////////////////////////////////////////////*/

    function pricingInfo() external view virtual returns (address refToken, bool refStrictlyEqual) {
        return (yieldToken, true);  // 1:1 with bullHYPE
    }
}
