// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../interfaces/IStabilityPool.sol";
import "../core/HypeZionExchange.sol";

/**
 * @title KinetiqYieldManager
 * @notice Manages yield harvesting and compounding from Kinetiq staking following Hylo's economic model
 * @dev Harvests kHYPE yield and compounds to StabilityPool as hzUSD
 *      - Staked hzUSD holders receive 100% of yield
 *      - xHYPE holders receive 0% yield (pure leverage exposure)
 *      - Harvest functions are permissionless (anyone can call)
 *      - All validation logic is in the contract
 *      - UUPS upgradeable pattern
 */
contract KinetiqYieldManager is AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant COMPOUND_COOLDOWN = 5 minutes; // Minimum time between compound operations

    // Kinetiq integration contract
    IKinetiqIntegration public kinetiqIntegration;

    // Protocol integration
    address payable public hypeZionExchange;
    address public stabilityPool;

    // Withdrawal tracking
    struct WithdrawalRequest {
        uint256 withdrawalId;      // Kinetiq withdrawal ID
        uint256 kHypeAmount;        // kHYPE amount withdrawn
        uint256 hypeAmount;         // HYPE amount (locked at queue time)
        uint256 queuedAt;          // Timestamp when queued
        bool claimed;              // Whether HYPE was claimed
    }
    WithdrawalRequest[] public pendingWithdrawals;
    mapping(uint256 => uint256) public withdrawalIdToIndex;  // Kinetiq ID -> array index
    
    // NAV tracking
    struct NAVSnapshot {
        uint256 khypeBalance;
        uint256 hypeValue;
        uint256 exchangeRate; // kHYPE to HYPE rate (18 decimals)
        uint256 timestamp;
        uint256 yieldAccrued;
    }
    
    // Historical NAV snapshots
    NAVSnapshot[] public navHistory;
    mapping(uint256 => NAVSnapshot) public navSnapshots; // timestamp => snapshot
    
    // Yield distribution
    uint256 public totalYieldHarvested;
    uint256 public lastHarvestTimestamp;
    uint256 public lastCompoundTimestamp; // Last time compound was executed
    uint256 public harvestInterval;

    // NAV thresholds and alerts
    uint256 public constant MIN_NAV_RATIO = 1e18; // 1.0 (kHYPE should never be worth less than HYPE)
    uint256 public navAlertThreshold;

    // Storage gap for future upgrades (UUPS pattern)
    uint256[50] private __gap; // Reduced from 50 to 49 (1 new slot used: lastCompoundTimestamp)

    // Events
    event NAVUpdated(uint256 indexed timestamp, uint256 khypeBalance, uint256 hypeValue, uint256 exchangeRate);
    event YieldHarvested(uint256 indexed timestamp, uint256 yieldAmount, address indexed harvester);
    event NAVAlert(uint256 indexed timestamp, uint256 currentRate, uint256 expectedRate);
    event HarvestIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event NAVAlertThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event YieldWithdrawalQueued(uint256 indexed withdrawalId, uint256 hypeAmount, uint256 timestamp);
    event YieldCompounded(uint256 indexed withdrawalId, uint256 hypeAmount, uint256 hzusdMinted, uint256 timestamp);
    event HypeZionExchangeSet(address indexed exchange);
    event StabilityPoolSet(address indexed pool);

    // Errors
    error InvalidNAV();
    error HarvestTooSoon();
    error NoYieldToHarvest();
    error NAVBelowMinimum();
    error InvalidInterval();
    error InvalidThreshold();
    error InvalidAddress();
    error OnlyExchange();
    error YieldTooSmall();
    error InsufficientRemaining();
    error WithdrawalNotReady();
    error AlreadyClaimed();
    error AmountMismatch();
    error CompoundTooSoon();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Called once during deployment through proxy
     * @param _kinetiqIntegration Address of KinetiqIntegration contract
     */
    function initialize(address _kinetiqIntegration) public initializer {
        require(_kinetiqIntegration != address(0), "Invalid Kinetiq address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        kinetiqIntegration = IKinetiqIntegration(_kinetiqIntegration);

        // Set default values
        harvestInterval = 1 days; // Default 24 hours
        navAlertThreshold = 95e16; // 0.95 - alert if NAV drops below 95% of expected

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice Receive HYPE from Kinetiq withdrawals
     * @dev Only accept HYPE from trusted sources: Kinetiq integration, exchange, or authorized roles
     */
    receive() external payable {
        require(
            msg.sender == address(kinetiqIntegration) ||
            msg.sender == hypeZionExchange ||
            hasRole(OPERATOR_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Unauthorized HYPE sender"
        );
    }

    /**
     * @notice Helper: Calculate total HYPE value of staked assets
     * @dev After vault integration, all kHYPE is held in the vault, not in KinetiqIntegration
     * @return Total HYPE value (vault kHYPE balance × exchange rate)
     */
    function _getTotalHYPEValue() internal view returns (uint256) {
        // Get kHYPE from Vault (all kHYPE is now in vault after integration)
        uint256 vaultKHYPE = 0;
        try HypeZionExchange(hypeZionExchange).getVaultKHYPEBalance() returns (uint256 balance) {
            vaultKHYPE = balance;
        } catch {
            // If exchange doesn't have vault or getVaultKHYPEBalance function, vault balance is 0
            vaultKHYPE = 0;
        }

        // Convert kHYPE to HYPE value
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
        return (vaultKHYPE * exchangeRate) / 1e18;
    }

    /**
     * @notice Update NAV snapshot from Kinetiq and Vault
     * @dev Fetches current exchange rate and balances from vault
     */
    function updateNAV() external onlyRole(OPERATOR_ROLE) {
        // Get kHYPE balance from vault and exchange rate
        uint256 khypeBalance = 0;
        try HypeZionExchange(hypeZionExchange).getVaultKHYPEBalance() returns (uint256 balance) {
            khypeBalance = balance;
        } catch {
            khypeBalance = 0;
        }
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();

        // Validate NAV is reasonable
        if (exchangeRate < MIN_NAV_RATIO) revert NAVBelowMinimum();

        // Calculate HYPE value
        uint256 hypeValue = (khypeBalance * exchangeRate) / 1e18;
        
        // Check for NAV anomaly
        if (exchangeRate < MIN_NAV_RATIO * navAlertThreshold / 1e18) {
            emit NAVAlert(block.timestamp, exchangeRate, MIN_NAV_RATIO);
        }
        
        // Calculate yield accrued since last snapshot
        uint256 yieldAccrued = 0;
        if (navHistory.length > 0) {
            NAVSnapshot memory lastSnapshot = navHistory[navHistory.length - 1];
            if (hypeValue > lastSnapshot.hypeValue) {
                yieldAccrued = hypeValue - lastSnapshot.hypeValue;
            }
        }
        
        // Create new snapshot
        NAVSnapshot memory snapshot = NAVSnapshot({
            khypeBalance: khypeBalance,
            hypeValue: hypeValue,
            exchangeRate: exchangeRate,
            timestamp: block.timestamp,
            yieldAccrued: yieldAccrued
        });
        
        // Store snapshot
        navHistory.push(snapshot);
        navSnapshots[block.timestamp] = snapshot;
        
        emit NAVUpdated(block.timestamp, khypeBalance, hypeValue, exchangeRate);
    }
    
    /**
     * @notice Calculate current yield available for harvesting
     * @dev Yield = Current HYPE value - Original deposits (from Exchange)
     * @return yieldInHYPE Amount of HYPE yield available
     */
    function calculateYield() public view returns (uint256 yieldInHYPE) {
        uint256 currentValue = _getTotalHYPEValue();
        uint256 totalUserDeposits = HypeZionExchange(hypeZionExchange).totalHYPECollateral();

        if (currentValue > totalUserDeposits) {
            yieldInHYPE = currentValue - totalUserDeposits;
        } else {
            yieldInHYPE = 0;
        }
    }

    /**
     * @notice Queue withdrawal of accumulated yield
     * @dev Permissionless - can be called by anyone. All validations are in the contract.
     *      Follows Hylo's economic model where yield goes to staked hzUSD holders.
     *      Enforces 5-minute cooldown between compound operations.
     * @return withdrawalId Kinetiq withdrawal ID
     */
    function queueYieldWithdrawal() external nonReentrant returns (uint256 withdrawalId) {
        // 0. Check cooldown period
        if (block.timestamp < lastCompoundTimestamp + COMPOUND_COOLDOWN) {
            revert CompoundTooSoon();
        }

        // 1. Calculate yield
        uint256 yieldInHYPE = calculateYield();
        if (yieldInHYPE == 0) revert NoYieldToHarvest();

        // 2. Check if yield meets minimum staking amount (required for re-minting hzUSD)
        uint256 minStakingAmount = kinetiqIntegration.getMinStakingAmount();
        if (yieldInHYPE < minStakingAmount) revert YieldTooSmall();

        // 3. Check if worth withdrawing (yield > withdrawal fee)
        uint256 totalUserDeposits = HypeZionExchange(hypeZionExchange).totalHYPECollateral();
        uint256 feeRate = kinetiqIntegration.getUnstakeFeeRate();  // 0.1% = 10 bps
        uint256 minYield = (totalUserDeposits * feeRate) / 10000;
        if (yieldInHYPE <= minYield) revert YieldTooSmall();

        // 4. Safety check: ensure remaining covers 100% redemption
        uint256 currentValue = _getTotalHYPEValue();
        uint256 remainingValue = currentValue - yieldInHYPE;
        if (remainingValue < totalUserDeposits) revert InsufficientRemaining();

        // 5. Convert HYPE to kHYPE for withdrawal
        uint256 exchangeRate = kinetiqIntegration.getExchangeRate();
        uint256 khypeAmount = (yieldInHYPE * 1e18) / exchangeRate;

        // 6. Request Exchange to withdraw mkHYPE from vault and transfer to Kinetiq
        HypeZionExchange(hypeZionExchange).withdrawKHYPEForYield(khypeAmount);

        // 7. Queue withdrawal from Kinetiq (mkHYPE is now in KinetiqIntegration)
        withdrawalId = kinetiqIntegration.queueUnstakeHYPE(khypeAmount);

        // 8. Track withdrawal
        uint256 index = pendingWithdrawals.length;
        pendingWithdrawals.push(WithdrawalRequest({
            withdrawalId: withdrawalId,
            kHypeAmount: 0,  // Will be calculated from hypeAmount
            hypeAmount: yieldInHYPE,
            queuedAt: block.timestamp,
            claimed: false
        }));
        withdrawalIdToIndex[withdrawalId] = index;

        // 9. Update compound timestamp to start cooldown
        lastCompoundTimestamp = block.timestamp;

        emit YieldWithdrawalQueued(withdrawalId, yieldInHYPE, block.timestamp);
        return withdrawalId;
    }

    /**
     * @notice Claim withdrawal and compound to StabilityPool (Hylo model)
     * @dev Permissionless - can be called by anyone. Claims ready withdrawals and compounds to pool.
     * @param withdrawalId Kinetiq withdrawal ID to claim
     */
    function claimAndCompound(uint256 withdrawalId) external nonReentrant {
        // 1. Verify withdrawal exists and is ready
        uint256 index = withdrawalIdToIndex[withdrawalId];
        require(index < pendingWithdrawals.length, "Invalid withdrawal index");
        WithdrawalRequest storage request = pendingWithdrawals[index];
        require(request.withdrawalId == withdrawalId, "Withdrawal ID mismatch");
        if (request.claimed) revert AlreadyClaimed();

        (bool ready, uint256 hypeAmount) = kinetiqIntegration.isUnstakeReady(withdrawalId);
        if (!ready) revert WithdrawalNotReady();

        // 2. Claim HYPE from Kinetiq
        uint256 hypeReceived = kinetiqIntegration.claimUnstake(withdrawalId);
        require(hypeReceived > 0, "No HYPE received");
        if (hypeReceived != hypeAmount) revert AmountMismatch();

        // 3. Mint hzUSD from HYPE
        require(hypeZionExchange != address(0), "Exchange not set");
        HypeZionExchange exchange = HypeZionExchange(payable(hypeZionExchange));
        uint256 hzusdMinted = exchange.mintStablecoin{value: hypeReceived}(hypeReceived);
        require(hzusdMinted > 0, "No hzUSD minted");

        // 4. Transfer hzUSD to StabilityPool
        address hzusd = address(exchange.zusd());
        require(hzusd != address(0), "HzUSD not set");
        require(stabilityPool != address(0), "StabilityPool not set");

        bool success = IERC20(hzusd).transfer(stabilityPool, hzusdMinted);
        require(success, "HzUSD transfer failed");

        // 5. Compound into StabilityPool (increases NAV without minting shares)
        IStabilityPool(stabilityPool).compoundYield(hzusdMinted);

        // 6. Mark as claimed
        request.claimed = true;

        // 7. Update harvest tracking and compound timestamp
        totalYieldHarvested += hypeReceived;
        lastHarvestTimestamp = block.timestamp;
        lastCompoundTimestamp = block.timestamp; // Update cooldown timer

        emit YieldCompounded(withdrawalId, hypeReceived, hzusdMinted, block.timestamp);
    }
    /**
     * @notice Get current NAV data
     * @return khypeBalance Current kHYPE balance
     * @return hypeValue Current HYPE value
     * @return exchangeRate Current exchange rate
     */
    function getCurrentNAV() external view returns (
        uint256 khypeBalance,
        uint256 hypeValue,
        uint256 exchangeRate
    ) {
        if (navHistory.length == 0) {
            return (0, 0, 1e18);
        }
        
        NAVSnapshot memory latest = navHistory[navHistory.length - 1];
        return (latest.khypeBalance, latest.hypeValue, latest.exchangeRate);
    }
    
    /**
     * @notice Get historical NAV at specific timestamp
     * @param timestamp Timestamp to query
     * @return snapshot NAV snapshot at timestamp
     */
    function getHistoricalNAV(uint256 timestamp) external view returns (NAVSnapshot memory) {
        return navSnapshots[timestamp];
    }
    
    /**
     * @notice Get NAV history within time range
     * @param fromIndex Starting index
     * @param toIndex Ending index
     * @return snapshots Array of NAV snapshots
     */
    function getNAVHistory(uint256 fromIndex, uint256 toIndex) 
        external 
        view 
        returns (NAVSnapshot[] memory snapshots) 
    {
        require(toIndex >= fromIndex, "Invalid range");
        require(toIndex < navHistory.length, "Index out of bounds");
        
        uint256 length = toIndex - fromIndex + 1;
        snapshots = new NAVSnapshot[](length);
        
        for (uint256 i = 0; i < length; i++) {
            snapshots[i] = navHistory[fromIndex + i];
        }
        
        return snapshots;
    }
    
    /**
     * @notice Calculate APY based on historical NAV
     * @param periodDays Number of days to calculate APY over
     * @return apy Annual percentage yield (basis points)
     */
    function calculateAPY(uint256 periodDays) external view returns (uint256 apy) {
        require(navHistory.length >= 2, "Insufficient history");
        require(periodDays > 0, "Invalid period");
        
        uint256 periodSeconds = periodDays * 1 days;
        uint256 currentTime = block.timestamp;
        
        // Find snapshot from period ago
        NAVSnapshot memory currentSnapshot = navHistory[navHistory.length - 1];
        NAVSnapshot memory periodSnapshot;
        bool found = false;
        
        for (int256 i = int256(navHistory.length) - 2; i >= 0; i--) {
            if (currentTime - navHistory[uint256(i)].timestamp >= periodSeconds) {
                periodSnapshot = navHistory[uint256(i)];
                found = true;
                break;
            }
        }
        
        if (!found) {
            periodSnapshot = navHistory[0];
        }
        
        // Calculate yield over period
        if (periodSnapshot.exchangeRate == 0) return 0;
        
        uint256 periodYield = ((currentSnapshot.exchangeRate - periodSnapshot.exchangeRate) * 10000) / 
                              periodSnapshot.exchangeRate;
        
        // Annualize
        uint256 periodsPerYear = 365 days / (currentTime - periodSnapshot.timestamp);
        apy = periodYield * periodsPerYear;
        
        return apy;
    }
    
    /**
     * @notice Set harvest interval
     * @param newInterval New interval in seconds
     */
    function setHarvestInterval(uint256 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newInterval == 0) revert InvalidInterval();
        
        uint256 oldInterval = harvestInterval;
        harvestInterval = newInterval;
        
        emit HarvestIntervalUpdated(oldInterval, newInterval);
    }
    
    /**
     * @notice Set NAV alert threshold
     * @param newThreshold New threshold (18 decimals, e.g., 0.95e18 for 95%)
     */
    function setNAVAlertThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0 || newThreshold > 1e18) revert InvalidThreshold();
        
        uint256 oldThreshold = navAlertThreshold;
        navAlertThreshold = newThreshold;
        
        emit NAVAlertThresholdUpdated(oldThreshold, newThreshold);
    }
    
    /**
     * @notice Check if harvest is available
     * @return canHarvestNow Whether harvest can be performed
     * @return timeUntilNext Time until next harvest (0 if can harvest now)
     */
    function canHarvest() external view returns (bool canHarvestNow, uint256 timeUntilNext) {
        uint256 nextHarvestTime = lastHarvestTimestamp + harvestInterval;
        
        if (block.timestamp >= nextHarvestTime) {
            return (true, 0);
        } else {
            return (false, nextHarvestTime - block.timestamp);
        }
    }

    /**
     * @notice Set HypeZionExchange address
     * @param _exchange Address of HypeZionExchange contract
     */
    function setHypeZionExchange(address _exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_exchange == address(0)) revert InvalidAddress();
        hypeZionExchange = payable(_exchange);
        emit HypeZionExchangeSet(_exchange);
    }

    /**
     * @notice Set StabilityPool address
     * @param _pool Address of StabilityPool contract
     */
    function setStabilityPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pool == address(0)) revert InvalidAddress();
        stabilityPool = _pool;
        emit StabilityPoolSet(_pool);
    }

    /**
     * @notice Get pending withdrawals that are ready to claim
     * @return claimable Array of claimable withdrawal requests
     */
    function getClaimableWithdrawals() external view returns (WithdrawalRequest[] memory claimable) {
        uint256 count = 0;
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (!pendingWithdrawals[i].claimed) {
                (bool ready,) = kinetiqIntegration.isUnstakeReady(pendingWithdrawals[i].withdrawalId);
                if (ready) count++;
            }
        }

        claimable = new WithdrawalRequest[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (!pendingWithdrawals[i].claimed) {
                (bool ready,) = kinetiqIntegration.isUnstakeReady(pendingWithdrawals[i].withdrawalId);
                if (ready) {
                    claimable[index] = pendingWithdrawals[i];
                    index++;
                }
            }
        }
    }

    /**
     * @notice Get all pending (unclaimed) withdrawals
     * @return pending Array of pending withdrawal requests
     */
    function getPendingWithdrawals() external view returns (WithdrawalRequest[] memory pending) {
        uint256 count = 0;
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (!pendingWithdrawals[i].claimed) count++;
        }

        pending = new WithdrawalRequest[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (!pendingWithdrawals[i].claimed) {
                pending[index] = pendingWithdrawals[i];
                index++;
            }
        }
    }

    /**
     * @notice Get comprehensive yield analytics
     * @return currentYield Current yield available for harvest
     * @return totalDeposits Total user deposits (principal)
     * @return currentValue Current kHYPE value in HYPE
     * @return pendingWithdrawalsCount Number of pending withdrawals
     * @return totalHarvested Total yield harvested all-time
     */
    function getYieldAnalytics() external view returns (
        uint256 currentYield,
        uint256 totalDeposits,
        uint256 currentValue,
        uint256 pendingWithdrawalsCount,
        uint256 totalHarvested
    ) {
        currentYield = calculateYield();
        totalDeposits = HypeZionExchange(hypeZionExchange).totalHYPECollateral();
        currentValue = _getTotalHYPEValue();

        // Count unclaimed withdrawals
        uint256 count = 0;
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (!pendingWithdrawals[i].claimed) count++;
        }
        pendingWithdrawalsCount = count;

        totalHarvested = totalYieldHarvested;
    }

    /**
     * @notice Authorize upgrade to new implementation
     * @dev Required by UUPS pattern, restricted to admin
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}