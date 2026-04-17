// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYieldSourceAdapter.sol";
import "../interfaces/ISwapWithdrawable.sol";
import "../interfaces/IKinetiqIntegration.sol";
import "../interfaces/IDexIntegration.sol";
import "./HypeZionExchange.sol";

/**
 * @title HypeZionExchangeRouter
 * @notice Internal distribution layer for multi-source yield management
 * @dev
 * Architecture (v2):
 *   User → Exchange → Router → Kinetiq + Valantis adapters
 *
 * Router is NO LONGER user-facing. Exchange is the single entry point.
 * Router handles:
 *   - distributeDeposit()       : split secondary HYPE across adapters on mint
 *   - withdrawFromSecondary()   : instant withdraw for swapRedeem
 *   - queueSecondaryWithdrawals(): queue adapter withdrawals for standard redeem
 *   - claimSecondaryWithdrawals(): claim queued adapter withdrawals
 *
 * Legacy claimRedemption() is kept for backward compatibility with any
 * CompositeRedemption entries created under the old architecture.
 */
contract HypeZionExchangeRouter is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    // ==================== ROLES ====================
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice Granted to Exchange contract — only Exchange may call distribution functions
    bytes32 public constant EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");

    // ==================== CONSTANTS ====================
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant TOTAL_WEIGHT = 10000;
    uint256 public constant MAX_SOURCES = 10;
    uint256 public constant DUST_THRESHOLD = 1e9; // Skip withdrawals below this to avoid wasting gas

    // ==================== SOURCE REGISTRY ====================

    struct YieldSource {
        address adapter;      // IYieldSourceAdapter contract address
        uint256 weight;       // Weight in basis points (e.g., 1500 = 15%)
        bool enabled;         // Legacy flag (kept for storage layout). Use mintEnabled/redeemEnabled.
        bool mintEnabled;     // Can new deposits go to this source?
        bool redeemEnabled;   // Can withdrawals come from this source?
        string name;          // Human-readable name (e.g., "Valantis kHYPE")
    }

    // Primary source: Exchange (Kinetiq)
    address payable public exchange;
    uint256 public primaryWeight;  // e.g., 7500 = 75%

    // Secondary sources
    YieldSource[] public sources;

    // DEPRECATED: Stored for storage layout compatibility. Do not use.
    // These slots were previously HzUSD and BullHYPE references used in user-facing v1 functions.
    address private _deprecatedZusd;
    address private _deprecatedZhype;

    // ==================== LEGACY COMPOSITE REDEMPTION (v1) ====================
    // Kept for backward compatibility — allows users with pending CompositeRedemptions
    // from the old architecture to claim their HYPE.

    struct CompositeRedemption {
        address user;
        uint256 legacyRedemptionId;
        uint256 tokenAmount;
        bool isZusd;
        bool claimed;
        uint256[] sourceTicketIds;
        uint256[] sourceExpectedHype;
    }

    uint256 public nextCompositeId;
    mapping(uint256 => CompositeRedemption) public compositeRedemptions;
    mapping(address => uint256[]) public userCompositeRedemptions;

    // ==================== SECONDARY TICKETS (v2) ====================

    struct SecondaryTicket {
        uint256[] sourceTicketIds;       // per-source ticket IDs from adapter.queueWithdraw
        uint256[] sourceExpectedHype;    // expected HYPE per source
        uint256[] extraTicketIds;        // redistribution tickets (from queue pass 2)
        uint256[] extraSourceIndices;    // which source each extra ticket belongs to
        bool[] sourceClaimed;            // per-source claim status
        bool[] extraClaimed;             // per-extra-ticket claim status
        bool claimed;                    // fully resolved (all claimed)
        uint256 totalHypeReceived;       // cumulative HYPE claimed across partial claims
        uint256 createdAt;               // timestamp for admin rescue timeout
    }

    uint256 public nextSecondaryTicketId;
    mapping(uint256 => SecondaryTicket) public secondaryTickets;

    // Yield source integrations — Router owns these so Exchange can delegate to Router
    // Consuming 2 more slots from __gap (33 → 31)
    address public kinetiq;          // IKinetiqIntegration address
    address public dexIntegration;   // IDexIntegration address

    // Storage gap — reduced from 35 to 31 (4 slots consumed)
    uint256[31] private __gap;

    // ==================== EVENTS ====================
    event DepositDistributed(uint256 totalHype, uint256[] toSources);
    event SecondaryWithdrawn(uint256 hypeAmount, uint256 hypeReceived);
    event SecondaryQueued(uint256 indexed ticketId, uint256 hypeAmount);
    event SecondaryClaimed(uint256 indexed ticketId, uint256 hypeReceived);

    event SourceAdded(uint256 indexed sourceIndex, string name, address adapter, uint256 weight);
    event SourceRemoved(uint256 indexed sourceIndex, string name);
    event SourceToggled(uint256 indexed sourceIndex, bool enabled);
    event SourceDisabledWithReserves(uint256 indexed sourceIndex, uint256 reserveAmount);
    event SourceMintToggled(uint256 indexed sourceIndex, bool enabled);
    event SourceRedeemToggled(uint256 indexed sourceIndex, bool enabled);
    event WeightsUpdated(uint256 primaryWeight, uint256[] sourceWeights);
    event SecondaryYieldHarvested(uint256 totalYield);
    event SecondaryReDepositFailed(uint256 sourceIndex, uint256 principal);
    event SecondaryQueueRedistributed(uint256 indexed ticketId, uint256 failedPortion, uint256 redistributed);
    event SecondaryClaimPending(uint256 indexed ticketId, uint256 pendingCount);
    event SecondaryRescued(uint256 indexed ticketId, uint256 sourceIndex, uint256 hypeReceived);

    // Legacy events (kept so old indexed events still parse)
    event CompositeRedeemClaimed(
        address indexed user,
        uint256 compositeId,
        uint256 totalHypeReceived
    );

    // ==================== ERRORS ====================
    error InvalidAmount();
    error ZeroAddress();
    error InvalidWeights();
    error NotYourRedemption();
    error AlreadyClaimed();
    error HYPETransferFailed();
    error InsufficientOutput();
    error TooManySources();
    error InvalidSourceIndex();
    error SourceNotEmpty();
    error TicketNotFound();
    error InsufficientYield();
    error RescueTimeoutNotReached();
    error SourceNotPending();

    // ==================== CONSTANTS ====================
    uint256 public constant RESCUE_TIMEOUT = 30 days;

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Router (v2 — no token references needed)
     * @param _exchange HypeZionExchange proxy address
     * @param _admin Admin address (receives all roles)
     */
    function initialize(
        address payable _exchange,
        address _admin
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_admin == address(0) || _exchange == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        exchange = _exchange;
        primaryWeight = TOTAL_WEIGHT; // 100% to Exchange initially
        nextCompositeId = 1;
        nextSecondaryTicketId = 1;
    }

    // ==================== SOURCE MANAGEMENT ====================

    /**
     * @notice Add a new secondary yield source
     */
    function addSource(
        address adapter,
        uint256 weight,
        string calldata name
    ) external onlyRole(ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (sources.length >= MAX_SOURCES) revert TooManySources();

        sources.push(YieldSource({
            adapter: adapter,
            weight: weight,
            enabled: true,
            mintEnabled: true,
            redeemEnabled: true,
            name: name
        }));

        _validateWeights();
        emit SourceAdded(sources.length - 1, name, adapter, weight);
    }

    /**
     * @notice Remove a secondary source via soft-delete (preserves index stability)
     * @dev Uses soft-delete instead of swap-and-pop to prevent corruption of
     *      pending SecondaryTicket/CompositeRedemption entries that reference
     *      sources by array index. The source's weight is returned to primary,
     *      and the slot is zeroed out but kept in the array.
     */
    function removeSource(uint256 index) external onlyRole(ADMIN_ROLE) {
        if (index >= sources.length) revert InvalidSourceIndex();
        if (sources[index].adapter == address(0)) revert InvalidSourceIndex(); // already removed

        uint256 reserve = IYieldSourceAdapter(sources[index].adapter).getReserveInHYPE();
        if (reserve > 0) revert SourceNotEmpty();

        string memory name = sources[index].name;
        primaryWeight += sources[index].weight;

        // Soft-delete: zero out the slot but keep the array length stable
        sources[index].adapter = address(0);
        sources[index].weight = 0;
        sources[index].enabled = false;
        sources[index].mintEnabled = false;
        sources[index].redeemEnabled = false;
        sources[index].name = "";

        _validateWeights();
        emit SourceRemoved(index, name);
    }

    /**
     * @notice Enable or disable a secondary source
     */
    /// @notice Legacy: enable/disable both mint and redeem (backward compatible)
    function setSourceEnabled(uint256 index, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (index >= sources.length) revert InvalidSourceIndex();
        sources[index].enabled = enabled;
        sources[index].mintEnabled = enabled;
        sources[index].redeemEnabled = enabled;
        emit SourceToggled(index, enabled);

        if (!enabled && sources[index].adapter != address(0)) {
            uint256 reserve = IYieldSourceAdapter(sources[index].adapter).getReserveInHYPE();
            if (reserve > 0) {
                emit SourceDisabledWithReserves(index, reserve);
            }
        }
    }

    /// @notice Disable mint only — source enters "Draining" state.
    ///         No new deposits, but existing funds can still be redeemed.
    ///         NAV still includes this source's reserves.
    function setMintEnabled(uint256 index, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (index >= sources.length) revert InvalidSourceIndex();
        sources[index].mintEnabled = enabled;
        // Update legacy flag: enabled = mintEnabled AND redeemEnabled
        sources[index].enabled = sources[index].mintEnabled && sources[index].redeemEnabled;
        emit SourceMintToggled(index, enabled);
    }

    /// @notice Disable redeem only — source marked as "Dead" (unresponsive).
    ///         No mint (auto-disabled) and no redeem.
    ///         NAV still includes reserves if funds exist (not lost, just inaccessible temporarily).
    function setRedeemEnabled(uint256 index, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (index >= sources.length) revert InvalidSourceIndex();
        sources[index].redeemEnabled = enabled;
        if (!enabled) sources[index].mintEnabled = false; // can't mint to dead source
        sources[index].enabled = sources[index].mintEnabled && sources[index].redeemEnabled;
        emit SourceRedeemToggled(index, enabled);
    }

    /**
     * @notice Update all weights at once
     */
    function updateWeights(
        uint256 _primaryWeight,
        uint256[] calldata _sourceWeights
    ) external onlyRole(ADMIN_ROLE) {
        if (_sourceWeights.length != sources.length) revert InvalidWeights();

        primaryWeight = _primaryWeight;
        for (uint256 i = 0; i < _sourceWeights.length; i++) {
            sources[i].weight = _sourceWeights[i];
        }

        _validateWeights();
        emit WeightsUpdated(_primaryWeight, _sourceWeights);
    }

    // ==================== DISTRIBUTION FUNCTIONS (v2) ====================
    // All gated by EXCHANGE_ROLE — only callable from HypeZionExchange

    /**
     * @notice Distribute HYPE across all yield sources (primary + secondary)
     * @dev Called by Exchange during mint with the FULL HYPE amount.
     *      1. Stakes primary portion via Kinetiq or DEX swap → kHYPE
     *      2. Transfers kHYPE back to Exchange (caller) for vault deposit
     *      3. Distributes secondary portion to adapter yield sources
     * @param swapData KyberSwap swap data (empty = use Kinetiq staking, non-empty = DEX swap)
     * @return kHYPEReceived kHYPE from primary Kinetiq/DEX staking (transferred to Exchange)
     * @return secondaryDeposited HYPE deposited to secondary adapters (for Exchange accounting)
     */
    function distributeDeposit(bytes calldata swapData) external payable onlyRole(EXCHANGE_ROLE) whenNotPaused
        returns (uint256 kHYPEReceived, uint256 secondaryDeposited)
    {
        uint256 total = msg.value;
        if (total == 0) return (0, 0);

        (uint256 effectivePrimary, uint256[] memory effectiveSecondary) = _getEffectiveWeights();

        // Split: primary and secondary amounts
        uint256 primaryHYPE = (total * effectivePrimary) / BASIS_POINTS;
        secondaryDeposited = total - primaryHYPE;

        // Pre-check Kinetiq minimum to avoid deep-call reverts on HyperEVM where try/catch
        // may not reliably catch string reverts at high call depth.
        if (kinetiq == address(0)) revert ZeroAddress();
        uint256 kinetiqMin = IKinetiqIntegration(kinetiq).getMinStakingAmount();

        // ---- PRIMARY: stake via Kinetiq or DEX swap → kHYPE → transfer to Exchange ----
        // DEX swap routes through AMM pools (e.g., Hybra) — independent of Kinetiq minimum.
        // Direct stakeHYPE requires kinetiqMin. Pre-check to avoid HyperEVM deep-call revert.
        if (primaryHYPE > 0) {
            bool primaryHandled = false;

            // 1. Try DEX swap first (no kinetiqMin check — DEX uses AMM pools, not Kinetiq)
            if (swapData.length > 0 && dexIntegration != address(0)) {
                try IDexIntegration(dexIntegration).swapToKHype{value: primaryHYPE}(swapData, 0) returns (uint256 dexKHYPE) {
                    kHYPEReceived = dexKHYPE;
                    primaryHandled = true;
                } catch {
                    // DEX failed — try stakeHYPE below if amount meets minimum
                }
            }

            // 2. If DEX failed or no swapData, try direct Kinetiq staking (requires minimum)
            if (!primaryHandled && primaryHYPE >= kinetiqMin) {
                try IKinetiqIntegration(kinetiq).stakeHYPE{value: primaryHYPE}(primaryHYPE) returns (uint256 stakedKHYPE) {
                    kHYPEReceived = stakedKHYPE;
                    primaryHandled = true;
                } catch {
                    // Unexpected failure — redirect to secondary
                    secondaryDeposited += primaryHYPE;
                }
            }

            // 3. Both failed or below minimum — redirect to secondary sources
            if (!primaryHandled) {
                secondaryDeposited += primaryHYPE;
            }

            if (primaryHandled) {
                address khypeToken = IKinetiqIntegration(kinetiq).getKHypeAddress();
                IERC20(khypeToken).safeTransfer(msg.sender, kHYPEReceived);
            }
        }

        // ---- SECONDARY: distribute to adapter yield sources ----
        if (secondaryDeposited > 0) {
            // Calculate total secondary weight for proportional split
            uint256 totalSecWeight = 0;
            for (uint256 i = 0; i < sources.length; i++) {
                totalSecWeight += effectiveSecondary[i];
            }

            if (totalSecWeight == 0) {
                // No active secondary sources — stake remainder directly with Kinetiq.
                uint256 extraKHYPE = IKinetiqIntegration(kinetiq).stakeHYPE{value: secondaryDeposited}(secondaryDeposited);
                address khypeToken = IKinetiqIntegration(kinetiq).getKHypeAddress();
                IERC20(khypeToken).safeTransfer(msg.sender, extraKHYPE);
                kHYPEReceived += extraKHYPE;
                secondaryDeposited = 0;  // No secondary deposit happened
            } else {
                // Find last enabled source for rounding remainder
                uint256 lastEnabled = type(uint256).max;
                for (uint256 i = 0; i < sources.length; i++) {
                    if (effectiveSecondary[i] > 0) lastEnabled = i;
                }

                uint256[] memory toSources = new uint256[](sources.length);
                uint256 allocated = 0;
                uint256 secondaryFallback = 0; // Track HYPE redirected to Kinetiq fallback

                for (uint256 i = 0; i < sources.length; i++) {
                    if (effectiveSecondary[i] == 0) continue;

                    uint256 portion = (i == lastEnabled)
                        ? secondaryDeposited - allocated
                        : (secondaryDeposited * effectiveSecondary[i]) / totalSecWeight;

                    if (i != lastEnabled) allocated += portion;

                    if (portion > 0 && sources[i].mintEnabled) {
                        try IYieldSourceAdapter(sources[i].adapter).deposit{value: portion}() {
                            toSources[i] = portion;
                        } catch {
                            // Adapter deposit failed — redirect portion to Kinetiq via direct staking.
                            // Pre-check Kinetiq minimum to avoid deep-call revert on HyperEVM.
                            if (portion >= kinetiqMin) {
                                try IKinetiqIntegration(kinetiq).stakeHYPE{value: portion}(portion) returns (uint256 extraKHYPE) {
                                    address khypeToken = IKinetiqIntegration(kinetiq).getKHypeAddress();
                                    IERC20(khypeToken).safeTransfer(msg.sender, extraKHYPE);
                                    kHYPEReceived += extraKHYPE;
                                } catch {
                                    // Kinetiq also failed — portion is lost (stays in Router as ETH)
                                }
                            }
                            // If below Kinetiq min or Kinetiq failed, HYPE stays in Router.
                            // This is acceptable for small amounts; admin can recover via sweep.
                            secondaryFallback += portion;
                        }
                    }
                }
                // Adjust secondaryDeposited and return stuck HYPE to Exchange
                secondaryDeposited -= secondaryFallback;
                if (secondaryFallback > 0) {
                    (bool ok, ) = payable(msg.sender).call{value: secondaryFallback}("");
                    // If return fails, HYPE stays in Router (admin can sweep)
                }

                emit DepositDistributed(total, toSources);
            }
        }
    }

    /**
     * @notice Swap kHYPE → HYPE via DEX and also withdraw from secondary sources
     * @dev Called by Exchange during swapRedeem. Exchange withdraws kHYPE from vault,
     *      transfers it here, and Router handles both the DEX swap and secondary withdrawal.
     *      Total HYPE is forwarded to Exchange (caller).
     * @param netKHYPE Amount of kHYPE to swap (already transferred to Router by Exchange)
     * @param swapData KyberSwap encoded swap data
     * @param secondaryPortion HYPE amount to withdraw from secondary sources
     * @param minHypeOut Minimum total HYPE out (slippage protection)
     * @return hypeReceived Total HYPE (from DEX swap + secondary withdrawal)
     */
    function swapKHYPEForHYPE(
        uint256 netKHYPE,
        bytes calldata swapData,
        uint256 secondaryPortion,
        bytes calldata secondarySwapData,
        uint256 minHypeOut
    ) external onlyRole(EXCHANGE_ROLE) returns (uint256 hypeReceived) {
        if (dexIntegration == address(0)) revert ZeroAddress();
        if (kinetiq == address(0)) revert ZeroAddress();

        address khypeToken = IKinetiqIntegration(kinetiq).getKHypeAddress();
        address native = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // Primary: DEX swap kHYPE → HYPE
        if (netKHYPE > 0) {
            IERC20(khypeToken).safeTransfer(address(dexIntegration), netKHYPE);
            hypeReceived = IDexIntegration(dexIntegration).executeSwap(
                swapData,
                khypeToken,
                native,
                netKHYPE,
                0,
                address(this)
            );
        }

        // Secondary: instant withdraw from adapters
        uint256 secondaryReceived = 0;
        if (secondaryPortion > 0) {
            secondaryReceived = _withdrawSecondarySources(secondaryPortion, secondarySwapData);
            hypeReceived += secondaryReceived;
        }

        // Combined slippage check: total output (primary DEX + secondary adapters) vs user's minHypeOut.
        // If ANY source returns less than expected (DEX slippage, adapter shortfall, pool drain),
        // the combined output drops below minHypeOut → revert. User can detect and adjust slippage.
        // Standard DeFi pattern — protects against both primary and secondary shortfalls.
        if (hypeReceived < minHypeOut) revert InsufficientOutput();

        // Forward total HYPE to Exchange (caller)
        if (hypeReceived > 0) {
            (bool ok, ) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }
    }

    /**
     * @notice Instantly withdraw HYPE from secondary sources (for swapRedeem)
     * @param hypeAmount Target HYPE to withdraw across secondary sources
     * @return hypeReceived Actual HYPE received (forwarded to Exchange as msg.sender)
     */
    function withdrawFromSecondary(uint256 hypeAmount) external onlyRole(EXCHANGE_ROLE) whenNotPaused returns (uint256 hypeReceived) {
        if (hypeAmount == 0) return 0;
        hypeReceived = _withdrawSecondarySources(hypeAmount, "");
        if (hypeReceived > 0) {
            (bool ok, ) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }
        emit SecondaryWithdrawn(hypeAmount, hypeReceived);
    }

    /**
     * @dev Internal instant withdrawal logic shared by withdrawFromSecondary and swapKHYPEForHYPE
     * @param hypeAmount Target HYPE to withdraw
     * @param secondarySwapData DEX swap data for adapters implementing ISwapWithdrawable (empty = skip)
     * @return hypeReceived Actual HYPE received (stays in Router until caller forwards it)
     */
    function _withdrawSecondarySources(uint256 hypeAmount, bytes memory secondarySwapData) internal returns (uint256 hypeReceived) {
        uint256 totalSecondaryReserves = _getRedeemableSecondaryReserves();
        if (totalSecondaryReserves == 0) return 0;

        if (hypeAmount > totalSecondaryReserves) hypeAmount = totalSecondaryReserves;

        // Snapshot reserves once — avoids repeated external calls to adapters
        uint256 len = sources.length;
        uint256[] memory reserves = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            if (!sources[i].redeemEnabled) continue;
            if (sources[i].adapter == address(0)) continue;
            IYieldSourceAdapter adapter = IYieldSourceAdapter(sources[i].adapter);
            if (!adapter.supportsInstantWithdraw()) continue;
            reserves[i] = adapter.getReserveInHYPE();
        }

        // First pass: try withdrawing proportional amounts from each source
        uint256 shortfall = 0;
        bool swapDataConsumed = false;

        for (uint256 i = 0; i < len; i++) {
            if (reserves[i] == 0) continue;

            uint256 portion = (hypeAmount * reserves[i]) / totalSecondaryReserves;
            if (portion > reserves[i]) portion = reserves[i];
            if (portion < DUST_THRESHOLD) continue;

            // Try swap-based withdrawal first for adapters that support it
            if (!swapDataConsumed && secondarySwapData.length > 0) {
                try ISwapWithdrawable(sources[i].adapter).instantWithdrawViaSwap(portion, secondarySwapData) returns (uint256 received) {
                    hypeReceived += received;
                    if (received < portion) shortfall += portion - received;
                    swapDataConsumed = true;
                    continue;
                } catch {}
            }

            // Fallback: regular instant withdraw
            try IYieldSourceAdapter(sources[i].adapter).instantWithdraw(portion) returns (uint256 received) {
                hypeReceived += received;
                if (received < portion) shortfall += portion - received;
            } catch {
                shortfall += portion;
            }
        }

        // Second pass: redistribute shortfall only if meaningful amount remains
        if (shortfall >= DUST_THRESHOLD) {
            // Re-read reserves only for sources that can still contribute
            uint256 totalRemaining = 0;
            for (uint256 i = 0; i < len; i++) {
                if (reserves[i] == 0) continue;
                reserves[i] = IYieldSourceAdapter(sources[i].adapter).getReserveInHYPE();
                totalRemaining += reserves[i];
            }

            if (totalRemaining > 0) {
                for (uint256 i = 0; i < len; i++) {
                    if (shortfall < DUST_THRESHOLD) break;
                    if (reserves[i] == 0) continue;

                    // Proportional allocation of shortfall across remaining reserves
                    uint256 extra = (shortfall * reserves[i]) / totalRemaining;
                    if (extra > reserves[i]) extra = reserves[i];
                    if (extra < DUST_THRESHOLD) continue;

                    try IYieldSourceAdapter(sources[i].adapter).instantWithdraw(extra) returns (uint256 received) {
                        hypeReceived += received;
                        shortfall -= (received > shortfall ? shortfall : received);
                    } catch {}
                }
            }
        }

        // Auto-drain: disable sources with 0 reserves that are redeem-only
        for (uint256 i = 0; i < len; i++) {
            if (!sources[i].mintEnabled && sources[i].redeemEnabled && sources[i].adapter != address(0))
                if (IYieldSourceAdapter(sources[i].adapter).getReserveInHYPE() == 0)
                { sources[i].redeemEnabled = false; sources[i].enabled = false; }
        }
    }

    /**
     * @notice Queue withdrawals from secondary sources (for standard queued redeem)
     * @param hypeAmount Target HYPE to queue across secondary sources
     * @return ticketId Secondary ticket ID to pass to claimSecondaryWithdrawals later
     */
    /// @dev Result from pass 1 of queue — avoids stack-too-deep in main function
    struct QueuePass1Result {
        uint256[] sourceTicketIds;
        uint256[] sourceExpectedHype;
        uint256[] sourceReserves;
        bool[] sourceQueued;
        uint256 failedPortion;
        uint256 successReserve;
    }

    function queueSecondaryWithdrawals(uint256 hypeAmount) external onlyRole(EXCHANGE_ROLE) whenNotPaused returns (uint256 ticketId) {
        if (hypeAmount == 0) return 0;

        uint256 totalSecondaryReserves = _getRedeemableSecondaryReserves();
        if (totalSecondaryReserves == 0) return 0;
        if (hypeAmount > totalSecondaryReserves) hypeAmount = totalSecondaryReserves;

        // Pass 1: try queue each source proportionally
        QueuePass1Result memory p1 = _queuePass1(hypeAmount, totalSecondaryReserves);

        // Pass 2: redistribute failed portion to successful sources
        uint256[] memory extraTicketIds = new uint256[](0);
        uint256[] memory extraSourceIndices = new uint256[](0);
        uint256 redistributed = 0;

        if (p1.failedPortion > 0 && p1.successReserve > 0) {
            (extraTicketIds, extraSourceIndices, redistributed) =
                _queuePass2Redistribute(p1);
        }

        // Store ticket
        ticketId = _storeSecondaryTicket(p1, extraTicketIds, extraSourceIndices);

        if (redistributed > 0) {
            emit SecondaryQueueRedistributed(ticketId, p1.failedPortion, redistributed);
        }
        emit SecondaryQueued(ticketId, hypeAmount);
    }

    function _queuePass1(uint256 hypeAmount, uint256 totalReserves) internal returns (QueuePass1Result memory result) {
        uint256 len = sources.length;
        result.sourceTicketIds = new uint256[](len);
        result.sourceExpectedHype = new uint256[](len);
        result.sourceReserves = new uint256[](len);
        result.sourceQueued = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            if (!sources[i].redeemEnabled || sources[i].adapter == address(0)) continue;

            IYieldSourceAdapter adapter = IYieldSourceAdapter(sources[i].adapter);
            uint256 reserve = adapter.getReserveInHYPE();
            result.sourceReserves[i] = reserve;
            if (reserve == 0) continue;

            uint256 portion = (hypeAmount * reserve) / totalReserves;
            if (portion > reserve) portion = reserve;
            if (portion == 0) continue;

            try adapter.queueWithdraw(portion) returns (uint256 sTicketId) {
                result.sourceTicketIds[i] = sTicketId;
                result.sourceExpectedHype[i] = portion;
                result.sourceQueued[i] = true;
                result.successReserve += reserve;
            } catch {
                result.failedPortion += portion;
            }
        }
    }

    function _queuePass2Redistribute(QueuePass1Result memory p1) internal
        returns (uint256[] memory extraTids, uint256[] memory extraIdxs, uint256 redistributed)
    {
        uint256 len = sources.length;
        extraTids = new uint256[](len);
        extraIdxs = new uint256[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            if (!p1.sourceQueued[i]) continue;

            uint256 extra = (p1.failedPortion * p1.sourceReserves[i]) / p1.successReserve;
            if (extra == 0) continue;

            uint256 remaining = IYieldSourceAdapter(sources[i].adapter).getReserveInHYPE();
            if (extra > remaining) extra = remaining;
            if (extra == 0) continue;

            try IYieldSourceAdapter(sources[i].adapter).queueWithdraw(extra) returns (uint256 tid) {
                extraTids[count] = tid;
                extraIdxs[count] = i;
                count++;
                p1.sourceExpectedHype[i] += extra;
                redistributed += extra;
            } catch {}
        }

        // Trim arrays to actual count
        if (count < len) {
            uint256[] memory trimTids = new uint256[](count);
            uint256[] memory trimIdxs = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                trimTids[i] = extraTids[i];
                trimIdxs[i] = extraIdxs[i];
            }
            return (trimTids, trimIdxs, redistributed);
        }
    }

    function _storeSecondaryTicket(
        QueuePass1Result memory p1,
        uint256[] memory extraTicketIds,
        uint256[] memory extraSourceIndices
    ) internal returns (uint256 ticketId) {
        uint256 len = p1.sourceQueued.length;
        ticketId = nextSecondaryTicketId++;
        SecondaryTicket storage ticket = secondaryTickets[ticketId];
        ticket.sourceTicketIds = p1.sourceTicketIds;
        ticket.sourceExpectedHype = p1.sourceExpectedHype;
        ticket.claimed = false;
        ticket.createdAt = block.timestamp;

        // Per-source claim tracking: non-queued = already done
        bool[] memory claimStatus = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            claimStatus[i] = !p1.sourceQueued[i];
        }
        ticket.sourceClaimed = claimStatus;

        // Store extra redistribution tickets
        if (extraTicketIds.length > 0) {
            ticket.extraTicketIds = extraTicketIds;
            ticket.extraSourceIndices = extraSourceIndices;
            ticket.extraClaimed = new bool[](extraTicketIds.length);
        }
    }

    /**
     * @notice Claim previously queued secondary withdrawals
     * @param ticketId Ticket ID returned by queueSecondaryWithdrawals
     * @return hypeReceived Total HYPE received and forwarded to Exchange (msg.sender)
     */
    function claimSecondaryWithdrawals(uint256 ticketId) external onlyRole(EXCHANGE_ROLE) returns (uint256 hypeReceived) {
        SecondaryTicket storage ticket = secondaryTickets[ticketId];
        if (ticket.claimed) revert AlreadyClaimed();
        if (ticketId == 0) revert TicketNotFound();

        bool allClaimed = true;

        // Claim primary tickets (one per source)
        for (uint256 i = 0; i < ticket.sourceTicketIds.length; i++) {
            if (ticket.sourceClaimed.length > i && ticket.sourceClaimed[i]) continue; // already claimed
            if (ticket.sourceTicketIds[i] == 0) continue;
            if (i >= sources.length || sources[i].adapter == address(0)) continue;

            try IYieldSourceAdapter(sources[i].adapter).claimWithdraw(ticket.sourceTicketIds[i])
                returns (uint256 received) {
                hypeReceived += received;
                if (ticket.sourceClaimed.length > i) ticket.sourceClaimed[i] = true;
            } catch {
                allClaimed = false;
            }
        }

        // Claim extra redistribution tickets
        for (uint256 j = 0; j < ticket.extraTicketIds.length; j++) {
            if (ticket.extraClaimed.length > j && ticket.extraClaimed[j]) continue;
            uint256 srcIdx = ticket.extraSourceIndices[j];
            if (srcIdx >= sources.length || sources[srcIdx].adapter == address(0)) continue;

            try IYieldSourceAdapter(sources[srcIdx].adapter).claimWithdraw(ticket.extraTicketIds[j])
                returns (uint256 received) {
                hypeReceived += received;
                if (ticket.extraClaimed.length > j) ticket.extraClaimed[j] = true;
            } catch {
                allClaimed = false;
            }
        }

        ticket.totalHypeReceived += hypeReceived;

        if (allClaimed) {
            ticket.claimed = true;
        } else {
            // Count pending for event
            uint256 pendingCount = 0;
            for (uint256 i = 0; i < ticket.sourceClaimed.length; i++) {
                if (!ticket.sourceClaimed[i]) pendingCount++;
            }
            for (uint256 j = 0; j < ticket.extraClaimed.length; j++) {
                if (!ticket.extraClaimed[j]) pendingCount++;
            }
            emit SecondaryClaimPending(ticketId, pendingCount);
        }

        if (hypeReceived > 0) {
            (bool ok, ) = payable(msg.sender).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit SecondaryClaimed(ticketId, hypeReceived);
    }

    // ==================== LEGACY CLAIM (v1 backward compatibility) ====================

    /**
     * @notice Claim a CompositeRedemption from the old v1 architecture
     * @dev DEPRECATED — only for pending CompositeRedemptions created before the v2 upgrade.
     *      New redemptions go through Exchange.claimRedemption() directly.
     */
    function claimRedemption(uint256 compositeId) external nonReentrant returns (uint256 hypeReceived) {
        CompositeRedemption storage comp = compositeRedemptions[compositeId];
        if (comp.user != msg.sender) revert NotYourRedemption();
        if (comp.claimed) revert AlreadyClaimed();

        // Claim from Exchange (Kinetiq)
        hypeReceived = HypeZionExchange(exchange).claimRedemption(comp.legacyRedemptionId);

        // Claim from each secondary source
        for (uint256 i = 0; i < comp.sourceTicketIds.length; i++) {
            if (comp.sourceTicketIds[i] > 0 && i < sources.length) {
                try IYieldSourceAdapter(sources[i].adapter).claimWithdraw(comp.sourceTicketIds[i])
                    returns (uint256 sourceHype) {
                    hypeReceived += sourceHype;
                } catch {}
            }
        }

        comp.claimed = true;

        (bool success, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!success) revert HYPETransferFailed();

        emit CompositeRedeemClaimed(msg.sender, compositeId, hypeReceived);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get total reserve value across ALL sources (primary Exchange + secondaries)
     * @dev After v2 refactor, Exchange.getTotalReserveInHYPE() already includes secondaries.
     *      This delegates to Exchange for the canonical combined value.
     */
    function getTotalReserveInHYPE() public view returns (uint256) {
        return HypeZionExchange(exchange).getTotalReserveInHYPE();
    }

    /**
     * @notice Get total reserve held in secondary sources only (excludes Exchange)
     */
    function getTotalSecondaryReserveInHYPE() external view returns (uint256) {
        return _getTotalSecondaryReserves();
    }

    /**
     * @notice Get total cost basis across all enabled secondary adapters.
     * @dev Queries each adapter's getTotalDeposited() directly — always accurate,
     *      unlike Exchange.totalSecondaryCollateral which can become stale after
     *      harvest re-deposit failures or adapter value losses.
     */
    function getTotalSecondaryDeposited() external view returns (uint256 total) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].adapter == address(0)) continue;
            total += IYieldSourceAdapter(sources[i].adapter).getTotalDeposited();
        }
    }

    /**
     * @notice Get combined zHYPE NAV (delegates to Exchange which includes secondaries)
     */
    function getZhypeNavInHYPE() public view returns (uint256) {
        return HypeZionExchange(exchange).getZhypeNavInHYPE();
    }

    /**
     * @notice Get zUSD NAV (delegates to Exchange)
     */
    function getZusdNavInHYPE() public view returns (uint256) {
        return HypeZionExchange(exchange).getZusdNavInHYPE();
    }

    /**
     * @notice Get system collateral ratio (delegates to Exchange)
     */
    function getSystemCR() external view returns (uint256) {
        return HypeZionExchange(exchange).getSystemCR();
    }

    /**
     * @notice Get protocol fee
     */
    function getProtocolFee(bool isZusd, bool isMint) external view returns (uint256) {
        return HypeZionExchange(exchange).getProtocolFee(isZusd, isMint);
    }

    // ==================== KINETIQ PROXY ====================

    function getExchangeRate() external view returns (uint256) {
        return IKinetiqIntegration(kinetiq).getExchangeRate();
    }

    function getKHypeAddress() external view returns (address) {
        return IKinetiqIntegration(kinetiq).getKHypeAddress();
    }

    function getWithdrawalDelay() external view returns (uint256) {
        return IKinetiqIntegration(kinetiq).getWithdrawalDelay();
    }

    function getYieldManager() external view returns (address) {
        return IKinetiqIntegration(kinetiq).getYieldManager();
    }

    /**
     * @notice Queue a primary Kinetiq withdrawal
     * @dev Exchange must transfer netKHYPE to Router before calling this
     */
    function queuePrimaryWithdrawal(uint256 netKHYPE)
        external onlyRole(EXCHANGE_ROLE) returns (uint256 kinetiqTicket)
    {
        address khypeToken = IKinetiqIntegration(kinetiq).getKHypeAddress();
        IERC20(khypeToken).safeTransfer(kinetiq, netKHYPE);
        kinetiqTicket = IKinetiqIntegration(kinetiq).queueUnstakeHYPE(netKHYPE);
    }

    function isPrimaryWithdrawalReady(uint256 kinetiqTicket)
        external view returns (bool ready, uint256 expectedHype)
    {
        return IKinetiqIntegration(kinetiq).isUnstakeReady(kinetiqTicket);
    }

    /**
     * @notice Claim a primary Kinetiq withdrawal and forward HYPE to Exchange
     */
    function claimPrimaryWithdrawal(uint256 kinetiqTicket)
        external onlyRole(EXCHANGE_ROLE) returns (uint256 hypeReceived)
    {
        hypeReceived = IKinetiqIntegration(kinetiq).claimUnstake(kinetiqTicket);
        (bool ok, ) = payable(msg.sender).call{value: hypeReceived}("");
        if (!ok) revert HYPETransferFailed();
    }

    /**
     * @notice Harvest yield from all enabled secondary sources.
     * @dev Only callable by the KinetiqYieldManager (verified via kinetiq.getYieldManager()).
     *
     *      Uses the full-exit + re-deposit pattern to correctly crystallise yield:
     *        1. Exit the entire LP position for a source  → receive HYPE back
     *        2. Re-deposit the original cost basis (getTotalDeposited() before exit)
     *        3. Keep the remainder as yield HYPE
     *
     *      This resets each adapter's cost basis so that subsequent calls to
     *      captureValantisMetrics() correctly show zero accrued yield.
     *
     *      In the normal case (re-deposit succeeds), Exchange.totalSecondaryCollateral
     *      stays correct because the adapter's cost basis is fully restored.
     *      Only when re-deposit fails does totalSecondaryCollateral become stale
     *      (the principal is treated as yield), but NAV uses actual reserves so
     *      pricing remains accurate. A SecondaryReDepositFailed event is emitted
     *      so off-chain monitoring can detect and reconcile this edge case.
     *
     *      Sources with yield < 0.001 HYPE are skipped to avoid dust transactions.
     *      If re-deposit of principal fails, the full received amount is treated as yield.
     *
     * @param minYield Minimum total HYPE yield required across all sources.
     *                 Pass 0 to harvest any non-dust amount.
     * @return totalYield Total HYPE forwarded to msg.sender (YieldManager).
     */
    function harvestSecondaryYield(uint256 minYield)
        external nonReentrant whenNotPaused returns (uint256 totalYield)
    {
        if (msg.sender != IKinetiqIntegration(kinetiq).getYieldManager()) revert ZeroAddress();

        for (uint256 i = 0; i < sources.length; i++) {
            if (!sources[i].redeemEnabled) continue;

            IYieldSourceAdapter adapter = IYieldSourceAdapter(sources[i].adapter);

            uint256 reserve  = adapter.getReserveInHYPE();
            uint256 deposited = adapter.getTotalDeposited();

            // Skip if no yield or if adapter has no position
            if (reserve == 0 || reserve <= deposited) continue;
            if (reserve - deposited < 0.001 ether) continue; // dust guard

            // --- Step 1: exit full LP position ---
            uint256 balBefore = address(this).balance;
            try adapter.instantWithdraw(reserve) {
                uint256 received = address(this).balance - balBefore;
                if (received == 0) continue;

                // Step 2: re-deposit original cost basis (capped to what we received)
                uint256 principal = deposited < received ? deposited : received;
                uint256 yield = received - principal;

                if (principal > 0) {
                    try adapter.deposit{value: principal}() {
                        // Principal restored — only yield is harvested
                    } catch {
                        // Re-deposit failed: treat everything as yield, principal lost to adapter.
                        // Exchange.totalSecondaryCollateral becomes stale for this source,
                        // but NAV uses actual reserves so pricing is unaffected.
                        yield = received;
                        emit SecondaryReDepositFailed(i, principal);
                    }
                }

                totalYield += yield;
            } catch {
                continue; // Adapter unavailable — skip silently
            }
        }

        if (totalYield < minYield) revert InsufficientYield();

        if (totalYield > 0) {
            (bool ok, ) = payable(msg.sender).call{value: totalYield}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit SecondaryYieldHarvested(totalYield);
    }

    function getSourceCount() external view returns (uint256) {
        return sources.length;
    }

    function getSource(uint256 index) external view returns (
        address adapter, uint256 weight, bool enabled, bool mintEnabled, bool redeemEnabled, string memory name
    ) {
        if (index >= sources.length) revert InvalidSourceIndex();
        YieldSource memory s = sources[index];
        return (s.adapter, s.weight, s.enabled, s.mintEnabled, s.redeemEnabled, s.name);
    }

    function getEffectiveWeights() external view returns (
        uint256 effectivePrimary,
        uint256[] memory effectiveSecondary
    ) {
        return _getEffectiveWeights();
    }

    /**
     * @notice Check if a secondary ticket is ready to claim
     */
    function isSecondaryTicketReady(uint256 ticketId) external view returns (bool ready) {
        SecondaryTicket storage ticket = secondaryTickets[ticketId];
        if (ticket.claimed) return false;
        if (ticketId == 0) return false;

        // Check primary tickets (skip already-claimed and disabled sources)
        for (uint256 i = 0; i < ticket.sourceTicketIds.length; i++) {
            if (ticket.sourceClaimed.length > i && ticket.sourceClaimed[i]) continue;
            if (ticket.sourceTicketIds[i] == 0) continue;
            if (i >= sources.length || sources[i].adapter == address(0)) continue;
            if (!sources[i].redeemEnabled) continue; // disabled source — skip readiness check
            if (!IYieldSourceAdapter(sources[i].adapter).isWithdrawReady(ticket.sourceTicketIds[i])) {
                return false;
            }
        }
        // Check extra redistribution tickets
        for (uint256 j = 0; j < ticket.extraTicketIds.length; j++) {
            if (ticket.extraClaimed.length > j && ticket.extraClaimed[j]) continue;
            uint256 srcIdx = ticket.extraSourceIndices[j];
            if (srcIdx >= sources.length || sources[srcIdx].adapter == address(0)) continue;
            if (!sources[srcIdx].redeemEnabled) continue; // disabled source — skip
            if (!IYieldSourceAdapter(sources[srcIdx].adapter).isWithdrawReady(ticket.extraTicketIds[j])) {
                return false;
            }
        }
        return true;
    }

    /// @notice Check if a secondary ticket is fully claimed (all sources resolved)
    function isSecondaryTicketFullyClaimed(uint256 ticketId) external view returns (bool) {
        return secondaryTickets[ticketId].claimed;
    }

    // Legacy view functions for backward compat
    function getCompositeRedemption(uint256 id) external view returns (
        address user, uint256 legacyRedemptionId, uint256 tokenAmount, bool isZusd, bool claimed
    ) {
        CompositeRedemption storage comp = compositeRedemptions[id];
        return (comp.user, comp.legacyRedemptionId, comp.tokenAmount, comp.isZusd, comp.claimed);
    }

    function getCompositeRedemptionTickets(uint256 id) external view returns (
        uint256[] memory sourceTicketIds,
        uint256[] memory sourceExpectedHype
    ) {
        CompositeRedemption storage comp = compositeRedemptions[id];
        return (comp.sourceTicketIds, comp.sourceExpectedHype);
    }

    function getUserCompositeRedemptions(address user) external view returns (uint256[] memory) {
        return userCompositeRedemptions[user];
    }

    function isRedemptionReady(uint256 compositeId) external view returns (bool ready, uint256 timeRemaining) {
        CompositeRedemption storage comp = compositeRedemptions[compositeId];
        if (comp.user == address(0) || comp.claimed) return (false, 0);

        (bool legacyReady, uint256 legacyTime) = HypeZionExchange(exchange)
            .isRedemptionReady(comp.legacyRedemptionId);
        if (!legacyReady) return (false, legacyTime);

        for (uint256 i = 0; i < comp.sourceTicketIds.length; i++) {
            if (comp.sourceTicketIds[i] > 0 && i < sources.length && sources[i].adapter != address(0)) {
                if (!IYieldSourceAdapter(sources[i].adapter).isWithdrawReady(comp.sourceTicketIds[i])) {
                    return (false, 0);
                }
            }
        }
        return (true, 0);
    }

    // ==================== INTERNAL HELPERS ====================

    /// @dev ALL secondary reserves (including disabled) — for NAV
    function _getTotalSecondaryReserves() internal view returns (uint256 total) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].adapter == address(0)) continue;
            try IYieldSourceAdapter(sources[i].adapter).getReserveInHYPE() returns (uint256 r) {
                total += r;
            } catch {}
        }
    }

    /// @dev Only redeemEnabled secondary reserves — for redeem split & withdrawal
    function _getRedeemableSecondaryReserves() internal view returns (uint256 total) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (!sources[i].redeemEnabled || sources[i].adapter == address(0)) continue;
            total += IYieldSourceAdapter(sources[i].adapter).getReserveInHYPE();
        }
    }

    /**
     * @notice Calculate effective weights, redistributing disabled sources proportionally
     * @dev Example: primary=7500, sources=[1500(ON), 1000(OFF)]
     *   disabledWeight=1000, activeWeight=7500+1500=9000
     *   effectivePrimary = 7500 + (1000 * 7500 / 9000) = 8333
     *   effectiveSource0 = 1500 + (1000 * 1500 / 9000) = 1667
     *   total = 10000 ✓
     */
    function _getEffectiveWeights() internal view returns (
        uint256 effectivePrimary,
        uint256[] memory effectiveSecondary
    ) {
        effectiveSecondary = new uint256[](sources.length);

        uint256 disabledWeight = 0;
        uint256 activeWeight = primaryWeight;

        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].mintEnabled) {
                activeWeight += sources[i].weight;
                effectiveSecondary[i] = sources[i].weight;
            } else {
                disabledWeight += sources[i].weight;
                effectiveSecondary[i] = 0;
            }
        }

        if (disabledWeight == 0) {
            effectivePrimary = primaryWeight;
            return (effectivePrimary, effectiveSecondary);
        }

        if (activeWeight == primaryWeight) {
            effectivePrimary = TOTAL_WEIGHT;
            return (effectivePrimary, effectiveSecondary);
        }

        effectivePrimary = primaryWeight + (disabledWeight * primaryWeight) / activeWeight;
        uint256 allocated = effectivePrimary;
        uint256 lastActive = type(uint256).max;

        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].mintEnabled) {
                effectiveSecondary[i] = sources[i].weight + (disabledWeight * sources[i].weight) / activeWeight;
                allocated += effectiveSecondary[i];
                lastActive = i;
            }
        }

        // Give rounding remainder to last active source
        if (allocated < TOTAL_WEIGHT && lastActive != type(uint256).max) {
            effectiveSecondary[lastActive] += TOTAL_WEIGHT - allocated;
        } else if (allocated < TOTAL_WEIGHT) {
            effectivePrimary += TOTAL_WEIGHT - allocated;
        }
    }

    function _validateWeights() internal view {
        uint256 total = primaryWeight;
        for (uint256 i = 0; i < sources.length; i++) {
            total += sources[i].weight;
        }
        if (total != TOTAL_WEIGHT) revert InvalidWeights();
    }

    // ==================== ADMIN ====================

    function setExchange(address payable _exchange) external onlyRole(ADMIN_ROLE) {
        if (_exchange == address(0)) revert ZeroAddress();
        exchange = _exchange;
    }

    function setKinetiq(address _kinetiq) external onlyRole(ADMIN_ROLE) {
        if (_kinetiq == address(0)) revert ZeroAddress();
        kinetiq = _kinetiq;
    }

    function setDexIntegration(address _dexIntegration) external onlyRole(ADMIN_ROLE) {
        if (_dexIntegration == address(0)) revert ZeroAddress();
        dexIntegration = _dexIntegration;
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    /**
     * @notice Admin rescue for stuck pending claims (after 30-day timeout)
     * @dev No try/catch — reverts on failure so admin sees the exact error.
     *      Only available after RESCUE_TIMEOUT (30 days) since ticket creation.
     * @param ticketId Secondary ticket ID
     * @param sourceIndex Source index to rescue
     * @return hypeReceived HYPE recovered from the stuck source
     */
    function rescuePendingClaim(uint256 ticketId, uint256 sourceIndex)
        external onlyRole(ADMIN_ROLE) nonReentrant
        returns (uint256 hypeReceived)
    {
        SecondaryTicket storage ticket = secondaryTickets[ticketId];
        if (ticket.claimed) revert AlreadyClaimed();
        if (ticketId == 0) revert TicketNotFound();
        if (block.timestamp < ticket.createdAt + RESCUE_TIMEOUT) revert RescueTimeoutNotReached();
        if (sourceIndex >= sources.length) revert InvalidSourceIndex();

        // Claim primary ticket for this source (no try/catch)
        if (ticket.sourceClaimed.length > sourceIndex && !ticket.sourceClaimed[sourceIndex]
            && ticket.sourceTicketIds.length > sourceIndex && ticket.sourceTicketIds[sourceIndex] != 0) {
            hypeReceived += IYieldSourceAdapter(sources[sourceIndex].adapter)
                .claimWithdraw(ticket.sourceTicketIds[sourceIndex]);
            ticket.sourceClaimed[sourceIndex] = true;
        }

        // Claim extra redistribution tickets for this source (no try/catch)
        for (uint256 j = 0; j < ticket.extraSourceIndices.length; j++) {
            if (ticket.extraSourceIndices[j] == sourceIndex
                && ticket.extraClaimed.length > j && !ticket.extraClaimed[j]) {
                hypeReceived += IYieldSourceAdapter(sources[sourceIndex].adapter)
                    .claimWithdraw(ticket.extraTicketIds[j]);
                ticket.extraClaimed[j] = true;
            }
        }

        if (hypeReceived == 0) revert SourceNotPending();

        ticket.totalHypeReceived += hypeReceived;

        // Check if all sources are now claimed
        bool allDone = true;
        for (uint256 i = 0; i < ticket.sourceClaimed.length; i++) {
            if (!ticket.sourceClaimed[i]) { allDone = false; break; }
        }
        if (allDone) {
            for (uint256 j = 0; j < ticket.extraClaimed.length; j++) {
                if (!ticket.extraClaimed[j]) { allDone = false; break; }
            }
        }
        if (allDone) ticket.claimed = true;

        // Forward HYPE to Exchange (user claims via reclaimPendingSecondary)
        if (hypeReceived > 0) {
            (bool ok, ) = payable(exchange).call{value: hypeReceived}("");
            if (!ok) revert HYPETransferFailed();
        }

        emit SecondaryRescued(ticketId, sourceIndex, hypeReceived);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    receive() external payable {}
}
