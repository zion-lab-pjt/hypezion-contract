// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../mocks/MockKHYPE.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockKinetiqIntegration
 * @notice Mock integration with Kinetiq for testnet
 * @dev Handles staking HYPE to receive zHYPE and NAV calculations
 */
contract MockKinetiqIntegration is IKinetiqIntegration, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    // Constants
    address public constant STAKING_MANAGER = 0x393D0B87Ed38fc779FD9611144aE649BA6082109;
    uint256 public constant MIN_STAKING_AMOUNT_DEFAULT = 5 ether; // 5 HYPE
    uint256 public constant MIN_STAKING_AMOUNT_LOWER = 0.01 ether; // 0.01 HYPE
    uint256 public constant MIN_STAKING_AMOUNT_UPPER = 1000 ether; // 1000 HYPE

    // State variables
    uint256 public minStakingAmount;

    // Mock kHYPE token for testing
    MockKHYPE public mockKHYPE;
    address public hypeNovaExchange;
    mapping(address => uint256) public stakedAmounts;
    uint256 public totalStaked;

    // Simple withdrawal tracking for mock
    // In production, this would be handled by Kinetiq's StakingManager contract
    uint256 public nextWithdrawalId;
    mapping(uint256 => uint256) public withdrawalAmounts; // withdrawalId => hypeAmount

    // Mock yield simulation for testing
    // In production, yield would be calculated by Kinetiq's StakingAccountant based on validator rewards
    uint256 public lastYieldUpdate;
    uint256 public accumulatedYield; // Total yield accumulated over time
    uint256 public constant ANNUAL_YIELD_RATE = 500; // 5% annual yield (500 basis points)
    uint256 public constant INITIAL_YIELD_BOOST = 250; // 2.5% initial yield (250 basis points)
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // New variables added in upgrade - must be at the end
    address public yieldManager; // Authorized to queue/claim withdrawals for yield
    mapping(uint256 => uint256) public withdrawalQueuedAt; // withdrawalId => timestamp when queued
    address public mockRouter; // MockKyberSwapRouter address (testnet only)

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap; // Reduced from 46 to 45 (3 new slots used)

    // Events
    event MinStakingAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event ExchangeSet(address indexed exchange);
    event HYPEWithdrawnForSwap(address indexed router, uint256 amount);
    event MockRouterSet(address indexed router);
    
    // Custom errors
    error InvalidAmount(uint256 amount, uint256 minimum);
    error InvalidRange(uint256 value, uint256 min, uint256 max);
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error StakingFailed(string reason);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // Prevent initialization of implementation contract
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during deployment through proxy
     * @param _mockKHYPEAddress Address of MockKHYPE token (for testnet)
     */
    function initialize(address _mockKHYPEAddress) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        minStakingAmount = MIN_STAKING_AMOUNT_DEFAULT;
        nextWithdrawalId = 1;
        lastYieldUpdate = block.timestamp;

        // Set mock kHYPE token address
        require(_mockKHYPEAddress != address(0), "Invalid MockKHYPE address");
        mockKHYPE = MockKHYPE(_mockKHYPEAddress);
    }

    /**
     * @notice Receive function to accept HYPE deposits for simulating yield
     * @dev Only accepts HYPE from operators or admin (mock version for testing)
     *      This simulates validator rewards that would accumulate in real Kinetiq
     */
    receive() external payable {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
    }

    /**
     * @notice Set the hypeNovaExchange address
     * @param _exchange Address of the hypeNovaExchange contract
     */
    function setExchange(address _exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_exchange == address(0)) revert ZeroAddress();
        hypeNovaExchange = _exchange;
        emit ExchangeSet(_exchange);
    }

    /**
     * @notice Set the yieldManager address
     * @param _yieldManager Address of the KinetiqYieldManager contract
     */
    function setYieldManager(address _yieldManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_yieldManager == address(0)) revert ZeroAddress();
        yieldManager = _yieldManager;
    }
    
    /**
     * @notice Stake HYPE tokens through Kinetiq StakingManager
     * @param amount Amount of HYPE to stake
     * @return kHYPEReceived Amount of kHYPE tokens received
     */
    function stakeHYPE(uint256 amount) external payable override nonReentrant returns (uint256 kHYPEReceived) {
        if (msg.sender != hypeNovaExchange) revert UnauthorizedCaller(msg.sender);
        if (amount < minStakingAmount) revert InvalidAmount(amount, minStakingAmount);
        require(msg.value == amount, "Incorrect HYPE amount sent");

        // Update yield before staking to ensure accurate exchange rate
        _updateYield();

        // In production, this would:
        // 1. Forward HYPE to Kinetiq StakingManager at 0x393D0B87Ed38fc779FD9611144aE649BA6082109
        // 2. Call StakingManager.stakeETH{value: amount}() to stake the HYPE
        // 3. Receive kHYPE tokens in return based on current exchange rate from StakingAccountant
        // For testing, we hold the HYPE in this contract and simulate the staking

        stakedAmounts[msg.sender] += amount;
        totalStaked += amount;

        // In production, would calculate kHYPE based on current exchange rate from StakingAccountant
        // For testing, calculate kHYPE based on current exchange rate (realistic simulation)
        uint256 currentRate = _calculateExchangeRate();
        kHYPEReceived = (amount * 1e18) / currentRate;

        // ✅ NEW: Mint mkHYPE tokens and transfer to Exchange
        mockKHYPE.mint(address(this), kHYPEReceived);
        IERC20(address(mockKHYPE)).safeTransfer(hypeNovaExchange, kHYPEReceived);

        emit HYPEStaked(amount, kHYPEReceived);
        return kHYPEReceived;
    }
    
    /**
     * @notice Get staked amount for an address
     * @param account Address to query
     * @return Amount of HYPE staked
     */
    function getStakedAmount(address account) external view returns (uint256) {
        return stakedAmounts[account];
    }
    
    /**
     * @notice Get kHYPE balance held by this contract
     * @return kHYPE token balance
     */
    function getKHYPEBalance() external view returns (uint256) {
        return IERC20(address(mockKHYPE)).balanceOf(address(this));
    }

    /**
     * @notice Get kHYPE token address
     * @return Address of kHYPE token
     * @dev Returns actual MockKHYPE token address
     */
    function getKHypeAddress() external view returns (address) {
        return address(mockKHYPE);
    }

    /**
     * @notice Internal function to update accumulated yield
     * @dev In production, yield would be tracked by StakingAccountant based on validator rewards
     */
    function _updateYield() internal {
        // In production, this would query StakingAccountant for actual validator rewards
        // For testing, we simulate yield accumulation based on time elapsed
        if (totalStaked > 0 && block.timestamp > lastYieldUpdate) {
            uint256 timeElapsed = block.timestamp - lastYieldUpdate;

            // Mock calculation: yield based on annual rate and time elapsed
            // In production, would be: StakingAccountant.getAccumulatedRewards()
            // yield = (totalStaked * ANNUAL_YIELD_RATE * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR)
            uint256 newYield = (totalStaked * ANNUAL_YIELD_RATE * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);

            accumulatedYield += newYield;
            lastYieldUpdate = block.timestamp;
        }
    }

    /**
     * @notice Calculate current exchange rate based on accumulated yield
     * @return Current exchange rate (1e18 = 1:1 ratio)
     * @dev In production, this would call StakingAccountant.getExchangeRate()
     */
    function _calculateExchangeRate() internal view returns (uint256) {
        // If nothing staked, return 1:1 ratio with initial boost
        if (totalStaked == 0) {
            return 1e18 + ((1e18 * INITIAL_YIELD_BOOST) / BASIS_POINTS);
        }

        // Calculate pending yield (not yet accumulated)
        uint256 pendingYield = 0;
        if (block.timestamp > lastYieldUpdate) {
            uint256 timeElapsed = block.timestamp - lastYieldUpdate;
            pendingYield = (totalStaked * ANNUAL_YIELD_RATE * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        }

        // Add initial boost to simulate existing yield
        // Initial boost: 2.5% of totalStaked
        uint256 initialBoost = (totalStaked * INITIAL_YIELD_BOOST) / BASIS_POINTS;

        // Exchange rate = total value / kHYPE balance
        // In mock, totalStaked represents initial kHYPE (1:1), so:
        // rate = (initialHYPE + initialBoost + accumulatedYield + pendingYield) / initialKHYPE
        uint256 totalValue = totalStaked + initialBoost + accumulatedYield + pendingYield;
        return (totalValue * 1e18) / totalStaked;
    }

    /**
     * @notice Get the exchange rate between kHYPE and HYPE
     * @return Exchange rate (HYPE per kHYPE, scaled by 1e18)
     * @dev This is functionally identical to getCurrentNAV() - both return HYPE per kHYPE.
     *      The duplication exists for interface compatibility with different Kinetiq contracts.
     */
    function getExchangeRate() external view override returns (uint256) {
        // In production, this would call StakingAccountant.getExchangeRate()
        // to get the actual exchange rate based on validator rewards
        // For testing, we calculate based on mock yield simulation
        return _calculateExchangeRate();
    }

    /**
     * @notice Force yield update
     * @dev Can be called by anyone to update the accumulated yield
     */
    function updateYield() external {
        _updateYield();
    }
    
    /**
     * @notice Queue kHYPE unstaking request (mock version)
     * @dev In production, this calls StakingManager.queueWithdrawal with kHYPE amount
     * @param khypeAmount Amount of kHYPE to unstake
     * @return withdrawalId ID of the withdrawal request
     */
    function queueUnstakeHYPE(uint256 khypeAmount) external override nonReentrant returns (uint256 withdrawalId) {
        if (msg.sender != hypeNovaExchange && msg.sender != yieldManager) revert UnauthorizedCaller(msg.sender);
        require(khypeAmount > 0, "Invalid amount");

        // Verify we have the mkHYPE (Exchange should have transferred it before calling)
        uint256 balance = IERC20(address(mockKHYPE)).balanceOf(address(this));
        require(balance >= khypeAmount, "Insufficient mkHYPE balance");

        // Convert kHYPE to HYPE using current exchange rate
        uint256 exchangeRate = _calculateExchangeRate();
        uint256 hypeAmount = (khypeAmount * exchangeRate) / 1e18;

        withdrawalId = nextWithdrawalId++;
        withdrawalAmounts[withdrawalId] = hypeAmount;
        withdrawalQueuedAt[withdrawalId] = block.timestamp; // Track when withdrawal was queued

        // Note: totalStaked is NOT reduced here - it's reduced when claimed
        // This matches the Exchange behavior where totalHYPECollateral is reduced on claim
        // Otherwise we get a timing mismatch: NAV drops immediately but collateral stays high

        // Burn the mkHYPE tokens (simulate Kinetiq burning kHYPE)
        mockKHYPE.burn(khypeAmount);

        emit UnstakeQueued(hypeAmount, withdrawalId, block.timestamp + 30 seconds);
        return withdrawalId;
    }

    /**
     * @notice Claim unstaked HYPE (mock version)
     * @dev In production, this would call StakingManager.completeQueuedWithdrawal
     * @param withdrawalId ID of the withdrawal to claim
     * @return hypeReceived Amount of HYPE received
     */
    function claimUnstake(uint256 withdrawalId) external override nonReentrant returns (uint256 hypeReceived) {
        if (msg.sender != hypeNovaExchange && msg.sender != yieldManager) revert UnauthorizedCaller(msg.sender);

        // In production, this would:
        // 1. Call StakingManager.completeQueuedWithdrawal(withdrawalId)
        // 2. Receive HYPE from StakingManager
        // 3. Forward HYPE to the exchange
        // For testing, we simulate the withdrawal completion

        uint256 expectedAmount = withdrawalAmounts[withdrawalId];
        require(expectedAmount > 0, "Invalid withdrawal");

        // Verify sufficient balance before transfer
        require(address(this).balance >= expectedAmount, "Insufficient balance");

        // Mock: In production, this would receive HYPE from StakingManager
        // For testing, HYPE is already in this contract
        hypeReceived = expectedAmount;

        // Reduce totalStaked when claiming (not when queuing)
        // This matches Exchange behavior where totalHYPECollateral is reduced on claim
        // Ensures NAV and collateral stay synchronized
        if (totalStaked >= hypeReceived) {
            totalStaked -= hypeReceived;
        }

        // Mark as claimed by deleting the amount and timestamp
        delete withdrawalAmounts[withdrawalId];
        delete withdrawalQueuedAt[withdrawalId];

        // Transfer HYPE to the caller (exchange or yieldManager)
        // In production, HYPE would come from StakingManager
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        require(success, "HYPE transfer failed");

        emit UnstakeClaimed(withdrawalId, hypeReceived, msg.sender);
        return hypeReceived;
    }

    /**
     * @notice Check if unstaking withdrawal is ready (mock version)
     * @param withdrawalId ID of the withdrawal to check
     * @return ready Always true for mock (no actual delay enforced)
     * @return hypeAmount Amount of HYPE that will be received
     */
    function isUnstakeReady(uint256 withdrawalId) external view override returns (bool ready, uint256 hypeAmount) {
        // In production, this would:
        // 1. Call StakingManager.withdrawalRequests(withdrawalId)
        // 2. Check if current timestamp >= withdrawal.readyTime
        // 3. Return the actual HYPE amount that will be received
        // For testing, check if delay has passed

        hypeAmount = withdrawalAmounts[withdrawalId];
        if (hypeAmount > 0) {
            uint256 queuedAt = withdrawalQueuedAt[withdrawalId];
            uint256 readyTime = queuedAt + 30 seconds; // Mock 30 second delay
            ready = block.timestamp >= readyTime;
        } else {
            ready = false;
        }
    }

    /**
     * @notice Get withdrawal delay in seconds
     * @return delaySeconds Delay before withdrawal can be claimed
     */
    function getWithdrawalDelay() external pure override returns (uint256 delaySeconds) {
        // In production, this would return StakingManager.withdrawalDelay()
        // which is typically 7 days for validator unstaking
        return 30 seconds; // Mock delay for testing
    }
    /**
     * @notice Get minimum staking amount
     * @return Minimum amount required for staking
     */
    function getMinStakingAmount() external view returns (uint256) {
        return minStakingAmount;
    }
    
    /**
     * @notice Set minimum staking amount (admin only)
     * @param newMinAmount New minimum staking amount
     */
    function setMinStakingAmount(uint256 newMinAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinAmount < MIN_STAKING_AMOUNT_LOWER || newMinAmount > MIN_STAKING_AMOUNT_UPPER) {
            revert InvalidRange(newMinAmount, MIN_STAKING_AMOUNT_LOWER, MIN_STAKING_AMOUNT_UPPER);
        }

        uint256 oldAmount = minStakingAmount;
        minStakingAmount = newMinAmount;

        emit MinStakingAmountUpdated(oldAmount, newMinAmount);
    }

    /**
     * @notice Get current unstaking fee rate (mock implementation)
     * @return Fee rate in basis points (e.g., 10 = 0.1%)
     */
    function getUnstakeFeeRate() external pure override returns (uint256) {
        return 10; // Mock 0.1% unstaking fee
    }

    /**
     * @notice Get the YieldManager address
     * @return Address of the KinetiqYieldManager contract
     */
    function getYieldManager() external view override returns (address) {
        return yieldManager;
    }

    /**
     * @notice Check if Kinetiq StakingManager is available
     * @return True if StakingManager is operational
     */
    function isStakingAvailable() external pure returns (bool) {
        // In production, this would:
        // 1. Check StakingManager.paused() status
        // 2. Check if validator set is accepting new stakes
        // 3. Verify minimum/maximum staking limits
        // For testing, always return true
        return true;
    }
    
    /**
     * @notice Simulate receiving staked tokens (for testing only)
     * @dev This function would not exist in production
     * @param recipient Address to receive tokens
     * @param amount Amount to simulate
     */
    function simulateStakedTokens(address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Mock function for testing - would not exist in production
        // In production, all staking goes through StakingManager
        stakedAmounts[recipient] += amount;
        totalStaked += amount;
    }

    /**
     * @notice Withdraw HYPE for swap redemption (called by MockKyberSwapRouter)
     * @dev Allows MockRouter to get HYPE for mkHYPE → HYPE swaps on testnet
     *      In production, this would not be needed as real KyberSwap has its own liquidity
     * @param amount Amount of HYPE to withdraw
     */
    function withdrawHYPEForSwap(uint256 amount) external nonReentrant {
        // Only allow MockKyberSwapRouter or admin to withdraw for swaps
        // This prevents unauthorized draining of staked HYPE
        require(
            msg.sender == mockRouter || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only MockRouter or admin"
        );

        // Verify we have enough HYPE
        require(address(this).balance >= amount, "Insufficient HYPE balance");

        // Transfer HYPE to caller (MockRouter)
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "HYPE transfer failed");

        emit HYPEWithdrawnForSwap(msg.sender, amount);
    }

    /**
     * @notice Set MockKyberSwapRouter address (testnet only)
     * @param _mockRouter Address of MockKyberSwapRouter
     */
    function setMockRouter(address _mockRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_mockRouter == address(0)) revert ZeroAddress();
        mockRouter = _mockRouter;
        emit MockRouterSet(_mockRouter);
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to admin
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}