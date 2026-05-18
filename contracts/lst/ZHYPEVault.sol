// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYieldSourceAdapter.sol";
import "./interfaces/IZHYPEVault.sol";
import "./interfaces/IZHYPEWithdrawalQueue.sol";
import "./ZHYPE.sol";
import "./ZHYPEWithdrawalQueue.sol";

contract ZHYPEVault is
    IZHYPEVault,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 private constant WEIGHT_DENOMINATOR = 10000; // 100% = 10000
    uint256 private constant DEAD_SHARES = 1000;
    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;

    ZHYPE public zHYPE;
    ZHYPEWithdrawalQueue public withdrawalQueue;

    address[] public adapters;
    mapping(address => uint256) public adapterWeights;
    mapping(address => bool) public isAdapter;

    uint256 public bufferTargetWeight;
    uint256 public minStakeAmount;

    uint256 public pendingWithdrawalHYPE;
    uint256 public reservedBuffer;

    uint256[32] private __gap;

    // ==================== EVENTS ====================

    event BufferTargetWeightUpdated(uint256 oldWeight, uint256 newWeight);
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);

    // ==================== ERRORS ====================

    error AdapterHasFunds(address adapter, uint256 reserve);
    error BufferWeightTooHigh(uint256 weight);
    error WithdrawalNotReady(uint256 requestId);
    error MinStakeTooLow(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _zHYPE,
        address _withdrawalQueue,
        address _admin
    ) external initializer {
        require(_zHYPE != address(0) && _withdrawalQueue != address(0) && _admin != address(0), "Zero address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        zHYPE = ZHYPE(_zHYPE);
        withdrawalQueue = ZHYPEWithdrawalQueue(_withdrawalQueue);
        bufferTargetWeight = 1000; // 10%
        minStakeAmount = 0.01 ether;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    // ==================== USER FUNCTIONS ====================

    function stake() external payable override nonReentrant whenNotPaused returns (uint256 zHYPEMinted) {
        if (msg.value == 0) revert ZeroDeposit();
        require(msg.value >= minStakeAmount, "Below minimum");
        if (adapters.length == 0) revert NoAdaptersConfigured();

        // Subtract msg.value since it's already in address(this).balance
        uint256 totalAssets = _activeTotalAssets() - msg.value;
        uint256 totalSupply = zHYPE.totalSupply();

        if (totalSupply == 0) {
            require(msg.value > DEAD_SHARES, "Below dead shares");
            zHYPEMinted = msg.value - DEAD_SHARES;
            zHYPE.mint(address(this), DEAD_SHARES);
            zHYPE.mint(msg.sender, zHYPEMinted);
        } else {
            zHYPEMinted = (msg.value * totalSupply) / totalAssets;
            zHYPE.mint(msg.sender, zHYPEMinted);
        }

        _distributeToAdapters(msg.value);

        emit Staked(msg.sender, msg.value, zHYPEMinted);
    }

    function requestWithdrawal(uint256 zHYPEAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (zHYPEAmount == 0) revert ZeroAmount();

        uint256 userBalance = zHYPE.balanceOf(msg.sender);
        if (userBalance < zHYPEAmount) revert InsufficientZHYPE(userBalance, zHYPEAmount);

        uint256 hypeAmount = convertToAssets(zHYPEAmount);

        IERC20(address(zHYPE)).safeTransferFrom(msg.sender, address(this), zHYPEAmount);
        zHYPE.burn(address(this), zHYPEAmount);

        // Try buffer first (only use unreserved buffer)
        uint256 availableBuffer = address(this).balance > reservedBuffer
            ? address(this).balance - reservedBuffer
            : 0;

        if (availableBuffer >= hypeAmount) {
            (bool ok,) = payable(msg.sender).call{value: hypeAmount}("");
            require(ok, "HYPE transfer failed");

            emit WithdrawalClaimed(msg.sender, 0, hypeAmount);
            return 0;
        }

        uint256 bufferUsed = availableBuffer;
        uint256 adapterNeeded = hypeAmount - bufferUsed;

        if (bufferUsed > 0) {
            reservedBuffer += bufferUsed;
        }

        IZHYPEWithdrawalQueue.AdapterTicket[] memory tickets = _queueFromAdapters(adapterNeeded);

        pendingWithdrawalHYPE += hypeAmount;

        requestId = withdrawalQueue.createRequest(
            msg.sender,
            zHYPEAmount,
            hypeAmount,
            tickets
        );

        emit WithdrawalRequested(msg.sender, requestId, zHYPEAmount, hypeAmount);
    }

    function claimWithdrawal(uint256 requestId)
        external
        override
        nonReentrant
        returns (uint256 hypeReceived)
    {
        (address owner,, uint256 hypeAmount,, uint256 claimableTime, bool claimed) =
            withdrawalQueue.getRequest(requestId);

        require(owner == msg.sender, "Not owner");
        require(!claimed, "Already claimed");
        if (block.timestamp < claimableTime) revert WithdrawalNotReady(requestId);

        // Claim from each adapter
        IZHYPEWithdrawalQueue.AdapterTicket[] memory tickets = withdrawalQueue.getAdapterTickets(requestId);
        uint256 adapterReceived = 0;

        for (uint256 i = 0; i < tickets.length; i++) {
            if (!tickets[i].claimed && tickets[i].hypeAmount > 0) {
                uint256 received = IYieldSourceAdapter(tickets[i].adapter).claimWithdraw(tickets[i].ticketId);
                adapterReceived += received;
                withdrawalQueue.markTicketClaimed(requestId, i);
            }
        }

        uint256 bufferPortion = hypeAmount > adapterReceived ? hypeAmount - adapterReceived : 0;
        if (bufferPortion > reservedBuffer) bufferPortion = reservedBuffer;

        hypeReceived = adapterReceived + bufferPortion;
        reservedBuffer -= bufferPortion;
        pendingWithdrawalHYPE -= hypeAmount;

        withdrawalQueue.markClaimed(requestId);

        if (hypeReceived > 0) {
            (bool ok,) = payable(msg.sender).call{value: hypeReceived}("");
            require(ok, "HYPE transfer failed");
        }

        emit WithdrawalClaimed(msg.sender, requestId, hypeReceived);
    }

    // ==================== OPERATOR FUNCTIONS ====================

    function rebalance() external onlyRole(OPERATOR_ROLE) whenNotPaused {
        uint256 totalAssets = _activeTotalAssets();
        if (totalAssets == 0) return;

        uint256 availableBuffer = address(this).balance > reservedBuffer
            ? address(this).balance - reservedBuffer
            : 0;
        uint256 targetBuffer = (totalAssets * bufferTargetWeight) / WEIGHT_DENOMINATOR;

        if (availableBuffer > targetBuffer) {
            uint256 excess = availableBuffer - targetBuffer;
            _distributeToAdapters(excess);
        }

        emit Rebalanced(block.timestamp);
    }

    function replenishBuffer(address adapter, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(isAdapter[adapter], "Not adapter");
        require(IYieldSourceAdapter(adapter).supportsInstantWithdraw(), "No instant withdraw");

        uint256 balBefore = address(this).balance;
        IYieldSourceAdapter(adapter).instantWithdraw(amount);
        uint256 actualReceived = address(this).balance - balBefore;

        emit BufferReplenished(actualReceived);
    }

    // ==================== ADMIN FUNCTIONS ====================

    function addAdapter(address adapter, uint256 targetWeight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isAdapter[adapter]) revert AdapterAlreadyExists(adapter);
        require(adapter != address(0), "Zero address");

        adapters.push(adapter);
        adapterWeights[adapter] = targetWeight;
        isAdapter[adapter] = true;

        emit AdapterAdded(adapter, targetWeight);
    }

    function removeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isAdapter[adapter]) revert AdapterNotFound(adapter);

        uint256 reserve = IYieldSourceAdapter(adapter).getReserveInHYPE();
        if (reserve > 0) revert AdapterHasFunds(adapter, reserve);

        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == adapter) {
                adapters[i] = adapters[adapters.length - 1];
                adapters.pop();
                break;
            }
        }

        delete adapterWeights[adapter];
        isAdapter[adapter] = false;

        emit AdapterRemoved(adapter);
    }

    function setTargetWeights(address[] calldata _adapters, uint256[] calldata weights)
        external
        onlyRole(MANAGER_ROLE)
    {
        require(_adapters.length == weights.length, "Length mismatch");

        uint256 totalWeight = bufferTargetWeight;
        for (uint256 i = 0; i < _adapters.length; i++) {
            require(isAdapter[_adapters[i]], "Not adapter");
            adapterWeights[_adapters[i]] = weights[i];
            totalWeight += weights[i];
        }
        if (totalWeight != WEIGHT_DENOMINATOR) revert WeightsSumInvalid(totalWeight);

        emit TargetWeightsUpdated(_adapters, weights);
    }

    function setBufferTargetWeight(uint256 weight) external onlyRole(MANAGER_ROLE) {
        if (weight >= WEIGHT_DENOMINATOR) revert BufferWeightTooHigh(weight);
        uint256 old = bufferTargetWeight;
        bufferTargetWeight = weight;
        emit BufferTargetWeightUpdated(old, weight);
    }

    function setMinStakeAmount(uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (amount <= DEAD_SHARES) revert MinStakeTooLow(amount);
        uint256 old = minStakeAmount;
        minStakeAmount = amount;
        emit MinStakeAmountUpdated(old, amount);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ==================== VIEW FUNCTIONS ====================

    function totalAssetsInHYPE() public view override returns (uint256 total) {
        total = address(this).balance;
        for (uint256 i = 0; i < adapters.length; i++) {
            total += IYieldSourceAdapter(adapters[i]).getReserveInHYPE();
        }
    }

    function convertToShares(uint256 hypeAmount) public view override returns (uint256) {
        uint256 totalSupply = zHYPE.totalSupply();
        if (totalSupply == 0) return hypeAmount;
        return (hypeAmount * totalSupply) / _activeTotalAssets();
    }

    function convertToAssets(uint256 zHYPEAmount) public view override returns (uint256) {
        uint256 totalSupply = zHYPE.totalSupply();
        if (totalSupply == 0) return zHYPEAmount;
        return (zHYPEAmount * _activeTotalAssets()) / totalSupply;
    }

    function getExchangeRate() external view override returns (uint256) {
        uint256 totalSupply = zHYPE.totalSupply();
        if (totalSupply == 0) return EXCHANGE_RATE_PRECISION;
        return (_activeTotalAssets() * EXCHANGE_RATE_PRECISION) / totalSupply;
    }

    function getAdapters() external view override returns (address[] memory) {
        return adapters;
    }

    function getAdapterWeight(address adapter) external view override returns (uint256) {
        return adapterWeights[adapter];
    }

    function getBufferBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    // ==================== INTERNAL ====================

    function _activeTotalAssets() internal view returns (uint256) {
        uint256 raw = totalAssetsInHYPE();
        return raw > reservedBuffer ? raw - reservedBuffer : 0;
    }

    function _distributeToAdapters(uint256 hypeAmount) internal {
        uint256 totalAdapterWeight = WEIGHT_DENOMINATOR - bufferTargetWeight;
        if (totalAdapterWeight == 0) return;

        uint256 bufferPortion = (hypeAmount * bufferTargetWeight) / WEIGHT_DENOMINATOR;
        uint256 remaining = hypeAmount - bufferPortion;

        for (uint256 i = 0; i < adapters.length; i++) {
            address adapter = adapters[i];
            uint256 adapterPortion;

            if (i == adapters.length - 1) {
                adapterPortion = remaining;
            } else {
                adapterPortion = (hypeAmount * adapterWeights[adapter]) / WEIGHT_DENOMINATOR;
                remaining -= adapterPortion;
            }

            if (adapterPortion > 0) {
                IYieldSourceAdapter(adapter).deposit{value: adapterPortion}();
            }
        }
    }

    function _queueFromAdapters(uint256 needed)
        internal
        returns (IZHYPEWithdrawalQueue.AdapterTicket[] memory tickets)
    {
        uint256 adapterCount = adapters.length;
        tickets = new IZHYPEWithdrawalQueue.AdapterTicket[](adapterCount);
        uint256 ticketCount = 0;

        for (uint256 i = 0; i < adapterCount && needed > 0; i++) {
            address adapter = adapters[i];
            uint256 adapterReserve = IYieldSourceAdapter(adapter).getReserveInHYPE();
            if (adapterReserve == 0) continue;

            uint256 withdrawAmount = needed <= adapterReserve ? needed : adapterReserve;
            uint256 ticketId = IYieldSourceAdapter(adapter).queueWithdraw(withdrawAmount);

            tickets[ticketCount] = IZHYPEWithdrawalQueue.AdapterTicket({
                adapter: adapter,
                ticketId: ticketId,
                hypeAmount: withdrawAmount,
                claimed: false
            });
            ticketCount++;
            needed -= withdrawAmount;
        }

        assembly {
            mstore(tickets, ticketCount)
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    receive() external payable {}
}
