// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../interfaces/IKinetiqIntegration.sol";
import "../external/kinetiq/IStakingManager.sol";
import "../external/kinetiq/IStakingAccountant.sol";
import "../external/kinetiq/IKHYPE.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title KinetiqIntegration
 * @notice Production integration with real Kinetiq contracts on HyperEVM mainnet
 * @dev ALL Kinetiq addresses are stored DIRECTLY HERE, not in HypeNovaExchange
 */
contract KinetiqIntegration is
    IKinetiqIntegration,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    // Kinetiq contract addresses stored DIRECTLY HERE as constants (not in HypeNovaExchange!)
    // Real mainnet addresses from https://kinetiq.xyz/docs/contracts-and-audits
    // If these need to change, deploy new implementation and upgrade via UUPS
    address public constant STAKING_MANAGER = 0x393D0B87Ed38fc779FD9611144aE649BA6082109;
    address public constant STAKING_ACCOUNTANT = 0x9209648Ec9D448EF57116B73A2f081835643dc7A;
    address public constant KHYPE_TOKEN = 0xfD739d4e423301CE9385c1fb8850539D657C296D;

    // Access control
    address public hypeNovaExchange;
    address public yieldManager; // Authorized to queue/claim withdrawals for yield

    // Storage for withdrawal tracking
    mapping(uint256 => uint256) public withdrawalKHYPEAmounts; // withdrawalId => kHYPE amount (excluding fee)
    mapping(uint256 => uint256) public withdrawalKHYPEFees;    // withdrawalId => kHYPE fee amount
    mapping(address => uint256) public stakedAmounts;          // account => staked amount

    // DEPRECATED: Global withdrawal ID counter (kept for storage layout compatibility)
    // @audit-fix Phase 1: No longer used - we now read from StakingManager.nextWithdrawalId(address)
    // WARNING: DO NOT REMOVE - Required for UUPS storage layout preservation
    uint256 public nextWithdrawalId;

    // Cross-function concurrency protection
    bool private _kinetiqOperationLock;                        // Prevents concurrent kHYPE operations

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap;

    // Events
    event ExchangeSet(address indexed exchange);
    event StakeCompleted(uint256 hypeAmount, uint256 kHYPEReceived);
    event WithdrawalQueued(uint256 withdrawalId, uint256 kHYPEAmount);
    event WithdrawalClaimed(uint256 withdrawalId, uint256 hypeReceived);

    // Custom errors
    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error InvalidWithdrawalId(uint256 id);
    error KinetiqOperationInProgress();

    /**
     * @dev Modifier to prevent concurrent operations that affect kHYPE balance
     * Prevents race conditions between stake/unstake/claim operations
     */
    modifier kinetiqOperationLock() {
        if (_kinetiqOperationLock) revert KinetiqOperationInProgress();
        _kinetiqOperationLock = true;
        _;
        _kinetiqOperationLock = false;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during deployment through proxy
     */
    function initialize() public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Set HypeNova exchange address
     * @param _exchange Exchange contract address
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
     * @notice Receive function to accept HYPE
     * @dev Only accepts HYPE from Kinetiq StakingManager or operators
     */
    receive() external payable {
        if (msg.sender != STAKING_MANAGER && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
    }

    /**
     * @notice Stake HYPE to receive kHYPE
     * @dev Uses modified CEI: stake() interaction must precede state update because we need
     *      the actual kHYPE received (balance diff). Reentrancy is prevented by nonReentrant
     *      + kinetiqOperationLock modifiers. Only safeTransfer occurs after state update.
     * @dev DEPRECATED: Use KyberSwapDexIntegration.swapToKHype() instead for better gas efficiency.
     *      This function is kept for backward compatibility and will be removed in future versions.
     * @param amount Amount of HYPE to stake
     * @return kHYPEReceived Amount of kHYPE tokens received
     */
    function stakeHYPE(uint256 amount) external payable override nonReentrant kinetiqOperationLock returns (uint256 kHYPEReceived) {
        // CHECKS: Validate all conditions first
        if (msg.sender != hypeNovaExchange) {
            revert UnauthorizedCaller(msg.sender);
        }
        require(msg.value == amount, "Incorrect HYPE amount");

        // Calculate expected kHYPE based on current exchange rate (for sanity check)
        uint256 exchangeRate = IStakingAccountant(STAKING_ACCOUNTANT).HYPEToKHYPE(1e18);
        uint256 expectedKHYPE = (amount * exchangeRate) / 1e18;

        // INTERACTION (trusted): Stake HYPE with Kinetiq and measure actual kHYPE received
        // Note: This interaction precedes state update intentionally - we need the actual
        // received amount. Reentrancy is blocked by nonReentrant + kinetiqOperationLock.
        uint256 kHYPEBefore = IERC20(KHYPE_TOKEN).balanceOf(address(this));
        IStakingManager(STAKING_MANAGER).stake{value: amount}();
        uint256 kHYPEAfter = IERC20(KHYPE_TOKEN).balanceOf(address(this));
        kHYPEReceived = kHYPEAfter - kHYPEBefore;

        // Sanity check: actual should be within 0.1% of expected
        require(
            kHYPEReceived >= (expectedKHYPE * 999) / 1000 &&
            kHYPEReceived <= (expectedKHYPE * 1001) / 1000,
            "kHYPE received amount mismatch"
        );

        // EFFECTS: Update state with actual received amount
        stakedAmounts[hypeNovaExchange] += kHYPEReceived;

        // INTERACTION: Transfer actual kHYPE received to Exchange (caller)
        IERC20(KHYPE_TOKEN).safeTransfer(msg.sender, kHYPEReceived);

        emit HYPEStaked(amount, kHYPEReceived);
        return kHYPEReceived;
    }

    /**
     * @notice Queue withdrawal of kHYPE to receive HYPE
     * @dev Follows CEI pattern: Checks-Effects-Interactions
     * @param khypeAmount Amount of kHYPE to unstake
     * @return withdrawalId The withdrawal request ID
     */
    function queueUnstakeHYPE(uint256 khypeAmount) external override nonReentrant kinetiqOperationLock returns (uint256 withdrawalId) {
        // CHECKS: Validate all conditions first
        if (msg.sender != hypeNovaExchange && msg.sender != yieldManager) {
            revert UnauthorizedCaller(msg.sender);
        }

        // EFFECTS & INTERACTIONS: Get withdrawal ID from StakingManager before queuing
        // Read the ID that StakingManager will assign BEFORE calling queueWithdrawal()
        IStakingManager stakingManager = IStakingManager(STAKING_MANAGER);
        withdrawalId = stakingManager.nextWithdrawalId(address(this));

        // Verify we have the kHYPE (Exchange should have transferred it before calling)
        uint256 balance = IERC20(KHYPE_TOKEN).balanceOf(address(this));
        require(balance >= khypeAmount, "Insufficient kHYPE balance");

        // Approve kHYPE transfer to StakingManager
        IERC20(KHYPE_TOKEN).approve(STAKING_MANAGER, khypeAmount);

        // Queue withdrawal with Kinetiq (using constant address)
        stakingManager.queueWithdrawal(khypeAmount);

        // Verify the withdrawal was created correctly
        IStakingManager.WithdrawalRequest memory kinetiqRequest =
            stakingManager.withdrawalRequests(address(this), withdrawalId);

        require(kinetiqRequest.hypeAmount > 0, "Withdrawal not created");

        // Store actual kHYPE amounts from Kinetiq (no assumptions!)
        withdrawalKHYPEAmounts[withdrawalId] = kinetiqRequest.kHYPEAmount; // Post-fee amount
        withdrawalKHYPEFees[withdrawalId] = kinetiqRequest.kHYPEFee;       // Actual fee

        // Note: stakedAmounts is NOT reduced here - it's reduced when claimed
        // Note: Exchange.totalHYPECollateral IS reduced at queue time (_executeRedeem)
        // because kHYPE leaves the vault immediately and no longer earns yield.
        // KinetiqIntegration.stakedAmounts is reduced at claim time for its own tracking.

        emit WithdrawalQueued(withdrawalId, khypeAmount);
        return withdrawalId;
    }

    /**
     * @notice Claim withdrawal after delay period
     * @dev Follows CEI pattern: Checks-Effects-Interactions
     * @param withdrawalId The withdrawal request ID
     * @return hypeReceived Amount of HYPE received
     */
    function claimUnstake(uint256 withdrawalId) external override nonReentrant kinetiqOperationLock returns (uint256 hypeReceived) {
        // CHECKS: Validate all conditions first
        if (msg.sender != hypeNovaExchange && msg.sender != yieldManager) {
            revert UnauthorizedCaller(msg.sender);
        }

        // Pre-query expected HYPE amount from Kinetiq (SAFE approach)
        IStakingManager.WithdrawalRequest memory request =
            IStakingManager(STAKING_MANAGER).withdrawalRequests(address(this), withdrawalId);

        require(request.hypeAmount > 0, "Invalid withdrawal request");
        require(block.timestamp >= request.timestamp + IStakingManager(STAKING_MANAGER).withdrawalDelay(),
                "Withdrawal not ready");

        uint256 expectedHype = request.hypeAmount;

        // EFFECTS: Update state before external calls
        // Reduce stakedAmounts when claiming (not when queuing)
        // Note: Exchange.totalHYPECollateral is reduced at queue time, but
        // KinetiqIntegration.stakedAmounts is reduced here at claim time.
        // Subtract BOTH post-fee amount AND fee from stakedAmounts to prevent accounting drift
        uint256 kHYPEAmount = withdrawalKHYPEAmounts[withdrawalId];  // Post-fee amount
        uint256 kHYPEFee = withdrawalKHYPEFees[withdrawalId];         // Fee amount
        uint256 totalKHYPE = kHYPEAmount + kHYPEFee;                  // Total original amount

        if (stakedAmounts[hypeNovaExchange] >= totalKHYPE) {
            stakedAmounts[hypeNovaExchange] -= totalKHYPE;  // Subtract full amount including fee
        }

        // Clear withdrawal tracking
        delete withdrawalKHYPEAmounts[withdrawalId];
        delete withdrawalKHYPEFees[withdrawalId];

        // INTERACTIONS: External calls last
        // Record balance before claiming
        uint256 balanceBefore = address(this).balance;

        // Confirm withdrawal with Kinetiq (using constant address)
        IStakingManager(STAKING_MANAGER).confirmWithdrawal(withdrawalId);

        // Calculate actual received amount
        uint256 balanceAfter = address(this).balance;
        require(balanceAfter >= balanceBefore, "Balance decreased");

        hypeReceived = balanceAfter - balanceBefore;
        require(hypeReceived > 0, "Nothing received");

        // Verify received amount matches expected (with small tolerance for rounding)
        require(
            hypeReceived >= expectedHype * 999 / 1000 &&
            hypeReceived <= expectedHype * 1001 / 1000,
            "Received amount mismatch"
        );

        // Forward actual received HYPE to caller (exchange or yieldManager)
        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        require(success, "Transfer failed");

        emit UnstakeClaimed(withdrawalId, hypeReceived, msg.sender);
        return hypeReceived;
    }

    /**
     * @notice Check if withdrawal is ready to claim
     * @param withdrawalId The withdrawal request ID
     * @return ready Whether withdrawal can be claimed
     * @return hypeAmount Expected HYPE amount
     */
    function isUnstakeReady(uint256 withdrawalId) external view override returns (bool ready, uint256 hypeAmount) {
        // Query real Kinetiq withdrawal status
        IStakingManager.WithdrawalRequest memory request =
            IStakingManager(STAKING_MANAGER).withdrawalRequests(address(this), withdrawalId);

        // Check if withdrawal exists
        if (request.timestamp == 0) {
            return (false, 0);
        }

        // Check if delay period has passed
        uint256 withdrawalDelay = IStakingManager(STAKING_MANAGER).withdrawalDelay();
        ready = block.timestamp >= request.timestamp + withdrawalDelay;
        hypeAmount = request.hypeAmount;
    }

    /**
     * @notice Get current exchange rate from Kinetiq
     * @return Exchange rate (HYPE per kHYPE) with 18 decimals
     */
    function getExchangeRate() external view override returns (uint256) {
        // Query real exchange rate from StakingAccountant (address stored HERE)
        return IStakingAccountant(STAKING_ACCOUNTANT).kHYPEToHYPE(1e18);
    }

    /**
     * @notice Get withdrawal delay in seconds
     * @return delaySeconds Withdrawal delay
     */
    function getWithdrawalDelay() external view override returns (uint256) {
        // Query real delay from StakingManager (constant address)
        return IStakingManager(STAKING_MANAGER).withdrawalDelay();
    }

    /**
     * @notice Get minimum staking amount
     * @return Minimum stake amount in HYPE
     */
    function getMinStakingAmount() external view override returns (uint256) {
        // Query from StakingManager
        return IStakingManager(STAKING_MANAGER).minStakeAmount();
    }

    /**
     * @notice Get staked amount for an account
     * @param account Account address
     * @return Staked kHYPE amount
     */
    function getStakedAmount(address account) external view returns (uint256) {
        return stakedAmounts[account];
    }

    /**
     * @notice Get kHYPE balance held by this contract
     * @return kHYPE token balance
     */
    function getKHYPEBalance() external view returns (uint256) {
        return IERC20(KHYPE_TOKEN).balanceOf(address(this));
    }

    /**
     * @notice Get kHYPE token address
     * @return Address of kHYPE token
     */
    function getKHypeAddress() external pure returns (address) {
        return KHYPE_TOKEN;
    }

    /**
     * @notice Check if staking is available
     * @return Available for staking (not paused)
     */
    function isStakingAvailable() external view returns (bool) {
        // Query real StakingManager for paused state
        return !IStakingManager(STAKING_MANAGER).stakingPaused();
    }

    /**
     * @notice Update yield (no-op for production)
     */
    function updateYield() external {
        // Exchange rate updates automatically in production
    }

    /**
     * @notice Simulate staked tokens (view only for production)
     * @param amount HYPE amount to simulate
     * @return Estimated kHYPE tokens
     */
    function simulateStakedTokens(uint256 amount) external view returns (uint256) {
        return IStakingAccountant(STAKING_ACCOUNTANT).HYPEToKHYPE(amount);
    }

    /**
     * @notice Set minimum staking amount (no-op, controlled by Kinetiq)
     */
    function setMinStakingAmount(uint256) external pure override {
        // Minimum is controlled by Kinetiq StakingManager
        revert("Controlled by Kinetiq");
    }

    /**
     * @notice Get current unstaking fee rate from Kinetiq
     * @return Fee rate in basis points (e.g., 10 = 0.1%)
     */
    function getUnstakeFeeRate() external view override returns (uint256) {
        return IStakingManager(STAKING_MANAGER).unstakeFeeRate();
    }

    /**
     * @notice Get the YieldManager address
     * @return Address of the KinetiqYieldManager contract
     */
    function getYieldManager() external view override returns (address) {
        return yieldManager;
    }

    /**
     * @notice Authorize upgrade (UUPS pattern)
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
