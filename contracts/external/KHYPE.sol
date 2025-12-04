// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title KHYPE
 * @notice Staked HYPE token representation
 */
contract KHYPE is ERC20 {
    address public stakingManager;
    
    modifier onlyStakingManager() {
        require(msg.sender == stakingManager, "KHYPE: caller is not staking manager");
        _;
    }
    
    constructor(address _stakingManager) ERC20("Kinetiq HYPE", "kHYPE") {
        stakingManager = _stakingManager;
    }
    
    function mint(address to, uint256 amount) external onlyStakingManager {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyStakingManager {
        _burn(from, amount);
    }
}