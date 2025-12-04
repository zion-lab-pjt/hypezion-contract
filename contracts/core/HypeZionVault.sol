// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title HypeZionVault
 * @notice Protocol vault for kHYPE reserves with strict access controls
 * @dev ERC-4626 compliant vault with security features
 *
 * Purpose:
 * - Safely store protocol's kHYPE reserves
 * - Provide ERC-4626 standard interface for deposits/withdrawals
 * - Restrict deposits to only EXCHANGE_ROLE
 * - Enforce rate limiting on withdrawals
 * - Support emergency pause capability
 *
 * Security Features:
 * - Deposit restriction: Only EXCHANGE_ROLE can deposit
 * - Withdrawal access: Anyone with shares can withdraw (only Exchange has shares)
 * - Rate limiting on withdrawals (per-user and global)
 * - Emergency pause capability
 * - UUPS upgradeability
 */
contract HypeZionVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ==================== Roles ====================

    bytes32 public constant EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");

    // ==================== State Variables ====================

    // Rate Limiting
    struct RateLimit {
        uint256 amount;        // Amount used in current window
        uint256 windowStart;   // Window start timestamp
        uint256 limit;         // Max amount per window
        uint256 windowSize;    // Window size in seconds
    }

    mapping(address => RateLimit) public userWithdrawalLimits; // Per-user limits
    RateLimit public globalWithdrawalLimit;                    // Global limit

    // Storage gap for future upgrades
    uint256[50] private __gap;

    // ==================== Events ====================

    event RateLimitUpdated(address indexed target, uint256 limit, uint256 windowSize);
    event WithdrawalExecuted(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    // ==================== Errors ====================

    error UnauthorizedCaller(address caller);
    error RateLimitExceeded(address caller, uint256 requested, uint256 available);

    // ==================== Initialization ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the vault
     * @param _asset Underlying asset (kHYPE)
     * @param _admin Admin address (receives DEFAULT_ADMIN_ROLE)
     */
    function initialize(
        address _asset,
        address _admin
    ) external initializer {
        // Initialize in linearization order
        // Note: __ERC4626_init internally calls __ERC20_init, so we don't call it separately
        __ERC20_init("HypeZion Vault", "hzVault");
        __ERC4626_init(IERC20(_asset));
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        // Default global limits (can be configured) - Effectively unlimited for testnet
        globalWithdrawalLimit.limit = type(uint256).max; // No practical limit for tests
        globalWithdrawalLimit.windowSize = 24 hours;
        globalWithdrawalLimit.windowStart = block.timestamp;
    }

    // ==================== Access Control ====================

    /**
     * @notice Set the exchange address and grant EXCHANGE_ROLE
     * @dev Only admin can call this. Used to break circular dependency during deployment.
     * @param _exchange Exchange contract address
     */
    function setExchange(address _exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_exchange != address(0), "Zero address");
        _grantRole(EXCHANGE_ROLE, _exchange);
    }

    /**
     * @notice Check if caller is authorized to deposit
     * @dev Only EXCHANGE_ROLE can deposit to vault
     */
    function _checkDepositAuthorization(address caller) internal view {
        if (!hasRole(EXCHANGE_ROLE, caller)) {
            revert UnauthorizedCaller(caller);
        }
    }

    // ==================== Rate Limiting ====================

    /**
     * @notice Set withdrawal rate limit for a user or globally
     * @param target User address to limit (address(0) for global)
     * @param limit Max amount per window
     * @param windowSize Window size in seconds
     */
    function setWithdrawalLimit(
        address target,
        uint256 limit,
        uint256 windowSize
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) {
            globalWithdrawalLimit.limit = limit;
            globalWithdrawalLimit.windowSize = windowSize;
        } else {
            userWithdrawalLimits[target].limit = limit;
            userWithdrawalLimits[target].windowSize = windowSize;
        }
        emit RateLimitUpdated(target, limit, windowSize);
    }

    /**
     * @notice Check and update rate limit for withdrawal
     * @param caller User address requesting withdrawal
     * @param amount Amount to withdraw
     */
    function _checkAndUpdateRateLimit(address caller, uint256 amount) internal {
        // Check per-user limit
        RateLimit storage userLimit = userWithdrawalLimits[caller];
        if (userLimit.limit > 0) {
            if (block.timestamp >= userLimit.windowStart + userLimit.windowSize) {
                userLimit.amount = 0;
                userLimit.windowStart = block.timestamp;
            }
            if (userLimit.amount + amount > userLimit.limit) {
                revert RateLimitExceeded(
                    caller,
                    amount,
                    userLimit.limit - userLimit.amount
                );
            }
            userLimit.amount += amount;
        }

        // Check global limit
        if (block.timestamp >= globalWithdrawalLimit.windowStart + globalWithdrawalLimit.windowSize) {
            globalWithdrawalLimit.amount = 0;
            globalWithdrawalLimit.windowStart = block.timestamp;
        }
        if (globalWithdrawalLimit.amount + amount > globalWithdrawalLimit.limit) {
            revert RateLimitExceeded(
                address(0),
                amount,
                globalWithdrawalLimit.limit - globalWithdrawalLimit.amount
            );
        }
        globalWithdrawalLimit.amount += amount;
    }

    /**
     * @notice Get remaining withdrawal capacity
     * @param user User address (address(0) for global)
     * @return remaining Amount available to withdraw
     */
    function getRemainingCapacity(address user) external view returns (uint256 remaining) {
        if (user == address(0)) {
            // Global capacity
            if (block.timestamp >= globalWithdrawalLimit.windowStart + globalWithdrawalLimit.windowSize) {
                return globalWithdrawalLimit.limit;
            }
            return globalWithdrawalLimit.limit - globalWithdrawalLimit.amount;
        } else {
            // Per-user capacity
            RateLimit storage userLimit = userWithdrawalLimits[user];
            if (userLimit.limit == 0) return type(uint256).max; // No limit
            if (block.timestamp >= userLimit.windowStart + userLimit.windowSize) {
                return userLimit.limit;
            }
            return userLimit.limit - userLimit.amount;
        }
    }

    // ==================== ERC-4626 Overrides ====================

    /**
     * @notice Deposit assets with authorization and pause check
     * @dev Only EXCHANGE_ROLE can deposit
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override nonReentrant whenNotPaused returns (uint256) {
        _checkDepositAuthorization(msg.sender);
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares with authorization and pause check
     * @dev Only EXCHANGE_ROLE can mint
     */
    function mint(
        uint256 shares,
        address receiver
    ) public virtual override nonReentrant whenNotPaused returns (uint256) {
        _checkDepositAuthorization(msg.sender);
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets with rate limit checks
     * @dev Anyone with shares can withdraw (but only Exchange has shares)
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override nonReentrant whenNotPaused returns (uint256) {
        _checkAndUpdateRateLimit(msg.sender, assets);

        uint256 shares = super.withdraw(assets, receiver, owner);

        emit WithdrawalExecuted(msg.sender, receiver, assets, shares);
        return shares;
    }

    /**
     * @notice Redeem shares with rate limit checks
     * @dev Anyone with shares can redeem (but only KINETIQ_INTEGRATION has shares)
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = previewRedeem(shares);
        _checkAndUpdateRateLimit(msg.sender, assets);

        assets = super.redeem(shares, receiver, owner);

        emit WithdrawalExecuted(msg.sender, receiver, assets, shares);
        return assets;
    }

    // ==================== Emergency Controls ====================

    /**
     * @notice Emergency pause vault
     * @dev Uses OpenZeppelin Pausable - can be unpaused by DEFAULT_ADMIN_ROLE
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause vault
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ==================== UUPS Upgrade ====================

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
