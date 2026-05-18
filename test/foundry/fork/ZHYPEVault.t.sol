// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../contracts/lst/ZHYPE.sol";
import "../../../contracts/lst/ZHYPEVault.sol";
import "../../../contracts/lst/ZHYPEWithdrawalQueue.sol";
import "../../../contracts/lst/adapters/KHYPEAdapter.sol";

// Mock adapter for testing — simulates yield source behavior
contract MockYieldAdapter {
    uint256 public totalDeposited;
    uint256 public reserveInHYPE;
    uint256 private _nextTicketId = 1;
    mapping(uint256 => uint256) public ticketAmounts;
    mapping(uint256 => bool) public ticketClaimed;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    mapping(address => bool) public hasVaultRole;

    modifier onlyVault() {
        require(hasVaultRole[msg.sender], "Not vault");
        _;
    }

    function grantVaultRole(address vault) external {
        hasVaultRole[vault] = true;
    }

    function deposit() external payable onlyVault returns (uint256) {
        totalDeposited += msg.value;
        reserveInHYPE += msg.value;
        return msg.value;
    }

    function instantWithdraw(uint256 hypeAmount) external onlyVault returns (uint256) {
        if (hypeAmount > reserveInHYPE) hypeAmount = reserveInHYPE;
        if (hypeAmount == 0) return 0;
        reserveInHYPE -= hypeAmount;
        (bool ok,) = payable(msg.sender).call{value: hypeAmount}("");
        require(ok);
        return hypeAmount;
    }

    function queueWithdraw(uint256 hypeAmount) external onlyVault returns (uint256 ticketId) {
        ticketId = _nextTicketId++;
        ticketAmounts[ticketId] = hypeAmount;
        reserveInHYPE -= hypeAmount;
        return ticketId;
    }

    function claimWithdraw(uint256 ticketId) external onlyVault returns (uint256) {
        require(!ticketClaimed[ticketId], "Already claimed");
        uint256 amount = ticketAmounts[ticketId];
        ticketClaimed[ticketId] = true;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok);
        return amount;
    }

    function getReserveInHYPE() external view returns (uint256) {
        return reserveInHYPE;
    }

    function getTotalDeposited() external view returns (uint256) {
        return totalDeposited;
    }

    function isOperational() external pure returns (bool) {
        return true;
    }

    function supportsInstantWithdraw() external pure returns (bool) {
        return true;
    }

    function isWithdrawReady(uint256 ticketId) external view returns (bool) {
        return ticketAmounts[ticketId] > 0 && !ticketClaimed[ticketId];
    }

    // Simulate yield accrual
    function accrueYield(uint256 amount) external payable {
        reserveInHYPE += amount;
    }

    receive() external payable {}
}

contract ZHYPEVaultTest is Test {
    ZHYPE public zHYPE;
    ZHYPEVault public vault;
    ZHYPEWithdrawalQueue public queue;
    MockYieldAdapter public adapter1;
    MockYieldAdapter public adapter2;

    address admin = address(this);
    address user1 = address(0xA11CE);
    address user2 = address(0xB0B);

    function setUp() public {
        // Deploy ZHYPE token
        ZHYPE zHYPEImpl = new ZHYPE();
        ERC1967Proxy zHYPEProxy = new ERC1967Proxy(
            address(zHYPEImpl),
            abi.encodeCall(ZHYPE.initialize, (admin))
        );
        zHYPE = ZHYPE(address(zHYPEProxy));

        // Deploy WithdrawalQueue
        ZHYPEWithdrawalQueue queueImpl = new ZHYPEWithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImpl),
            abi.encodeCall(ZHYPEWithdrawalQueue.initialize, (admin, 7 days))
        );
        queue = ZHYPEWithdrawalQueue(address(queueProxy));

        // Deploy Vault
        ZHYPEVault vaultImpl = new ZHYPEVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(ZHYPEVault.initialize, (address(zHYPE), address(queue), admin))
        );
        vault = ZHYPEVault(payable(address(vaultProxy)));

        // Deploy mock adapters
        adapter1 = new MockYieldAdapter();
        adapter2 = new MockYieldAdapter();
        adapter1.grantVaultRole(address(vault));
        adapter2.grantVaultRole(address(vault));

        // Configure roles
        zHYPE.grantRole(zHYPE.MINTER_ROLE(), address(vault));
        queue.grantRole(queue.VAULT_ROLE(), address(vault));

        // Register adapters: adapter1 60%, adapter2 30%, buffer 10%
        vault.addAdapter(address(adapter1), 6000);
        vault.addAdapter(address(adapter2), 3000);
        vault.setBufferTargetWeight(1000);

        // Fund test users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ==================== STAKE TESTS ====================

    function test_stake_firstDeposit() public {
        vm.prank(user1);
        uint256 minted = vault.stake{value: 1 ether}();

        // First deposit: 1 ether - 1000 (dead shares)
        assertEq(minted, 1 ether - 1000);
        assertEq(zHYPE.balanceOf(user1), minted);
        assertEq(zHYPE.totalSupply(), 1 ether); // includes dead shares
    }

    function test_stake_distribution() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // Buffer should be ~10% = 1 ether
        uint256 buffer = vault.getBufferBalance();
        assertEq(buffer, 1 ether);

        // adapter1 should have ~60% = 6 ether
        assertEq(adapter1.getReserveInHYPE(), 6 ether);

        // adapter2 should have ~30% = 3 ether
        assertEq(adapter2.getReserveInHYPE(), 3 ether);
    }

    function test_stake_secondDeposit() public {
        vm.prank(user1);
        vault.stake{value: 1 ether}();

        vm.prank(user2);
        uint256 minted = vault.stake{value: 2 ether}();

        // Second deposit at same rate: ~2 ether worth of shares
        assertApproxEqRel(minted, 2 ether, 0.001e18);
        assertEq(zHYPE.balanceOf(user2), minted);
    }

    function test_stake_zeroReverts() public {
        vm.prank(user1);
        vm.expectRevert(IZHYPEVault.ZeroDeposit.selector);
        vault.stake{value: 0}();
    }

    function test_stake_belowMinimumReverts() public {
        vm.prank(user1);
        vm.expectRevert("Below minimum");
        vault.stake{value: 0.001 ether}();
    }

    function test_stake_noAdaptersReverts() public {
        ZHYPEVault vaultImpl = new ZHYPEVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(ZHYPEVault.initialize, (address(zHYPE), address(queue), admin))
        );
        ZHYPEVault emptyVault = ZHYPEVault(payable(address(vaultProxy)));

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(IZHYPEVault.NoAdaptersConfigured.selector);
        emptyVault.stake{value: 1 ether}();
    }

    // ==================== EXCHANGE RATE TESTS ====================

    function test_exchangeRate_initial() public view {
        assertEq(vault.getExchangeRate(), 1e18);
    }

    function test_exchangeRate_afterStake() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        uint256 rate = vault.getExchangeRate();
        assertApproxEqRel(rate, 1e18, 0.001e18); // 1:1 right after
    }

    function test_exchangeRate_afterYield() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // Simulate yield: adapter1 earns 1 ether
        vm.deal(address(adapter1), address(adapter1).balance + 1 ether);
        adapter1.accrueYield(1 ether);

        // Rate should increase: totalAssets = 11, totalSupply = 10
        uint256 rate = vault.getExchangeRate();
        assertGt(rate, 1e18);
        assertApproxEqRel(rate, 1.1e18, 0.001e18);
    }

    function test_convertToShares() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        uint256 shares = vault.convertToShares(1 ether);
        assertApproxEqRel(shares, 1 ether, 0.001e18);
    }

    function test_convertToAssets() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        uint256 assets = vault.convertToAssets(1 ether);
        assertApproxEqRel(assets, 1 ether, 0.001e18);
    }

    function test_convertToAssets_afterYield() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // Yield: +1 ether
        vm.deal(address(adapter1), address(adapter1).balance + 1 ether);
        adapter1.accrueYield(1 ether);

        // 1 zHYPE should be worth > 1 HYPE now
        uint256 assets = vault.convertToAssets(1 ether);
        assertGt(assets, 1 ether);
    }

    // ==================== WITHDRAWAL TESTS ====================

    function test_requestWithdrawal_instantFromBuffer() public {
        vm.startPrank(user1);
        vault.stake{value: 10 ether}();

        // Request small amount (< buffer)
        uint256 smallShares = vault.convertToShares(0.5 ether);
        zHYPE.approve(address(vault), smallShares);

        uint256 balBefore = user1.balance;
        uint256 requestId = vault.requestWithdrawal(smallShares);
        uint256 balAfter = user1.balance;

        // Instant withdrawal: requestId = 0, user gets HYPE
        assertEq(requestId, 0);
        assertApproxEqRel(balAfter - balBefore, 0.5 ether, 0.01e18);
        vm.stopPrank();
    }

    function test_requestWithdrawal_queued() public {
        vm.startPrank(user1);
        vault.stake{value: 10 ether}();

        // Request large amount (> buffer)
        uint256 largeShares = vault.convertToShares(5 ether);
        zHYPE.approve(address(vault), largeShares);

        uint256 requestId = vault.requestWithdrawal(largeShares);

        // Should be queued (requestId > 0)
        assertGt(requestId, 0);
        vm.stopPrank();
    }

    function test_claimWithdrawal() public {
        vm.startPrank(user1);
        vault.stake{value: 10 ether}();

        uint256 largeShares = vault.convertToShares(5 ether);
        zHYPE.approve(address(vault), largeShares);
        uint256 requestId = vault.requestWithdrawal(largeShares);
        vm.stopPrank();

        // Warp past withdrawal delay
        vm.warp(block.timestamp + 7 days + 1);

        // Fund adapter for claim (simulating Kinetiq returning HYPE)
        vm.deal(address(adapter1), 10 ether);
        vm.deal(address(adapter2), 10 ether);

        vm.prank(user1);
        uint256 received = vault.claimWithdrawal(requestId);
        assertGt(received, 0);
    }

    function test_requestWithdrawal_zeroReverts() public {
        vm.prank(user1);
        vm.expectRevert(IZHYPEVault.ZeroAmount.selector);
        vault.requestWithdrawal(0);
    }

    function test_requestWithdrawal_insufficientBalance() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IZHYPEVault.InsufficientZHYPE.selector, 0, 1 ether));
        vault.requestWithdrawal(1 ether);
    }

    // ==================== VIEW FUNCTION TESTS ====================

    function test_totalAssetsInHYPE() public {
        vm.prank(user1);
        vault.stake{value: 5 ether}();

        uint256 totalAssets = vault.totalAssetsInHYPE();
        assertEq(totalAssets, 5 ether);
    }

    function test_getBufferBalance() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        uint256 buffer = vault.getBufferBalance();
        assertEq(buffer, 1 ether); // 10% of 10
    }

    function test_getAdapters() public view {
        address[] memory adapterList = vault.getAdapters();
        assertEq(adapterList.length, 2);
        assertEq(adapterList[0], address(adapter1));
        assertEq(adapterList[1], address(adapter2));
    }

    // ==================== ADMIN TESTS ====================

    function test_addAdapter() public {
        MockYieldAdapter adapter3 = new MockYieldAdapter();
        vault.addAdapter(address(adapter3), 500);
        assertEq(vault.getAdapterWeight(address(adapter3)), 500);
    }

    function test_addAdapter_duplicateReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IZHYPEVault.AdapterAlreadyExists.selector, address(adapter1)));
        vault.addAdapter(address(adapter1), 1000);
    }

    function test_removeAdapter() public {
        vault.removeAdapter(address(adapter2));
        assertEq(vault.getAdapterWeight(address(adapter2)), 0);

        address[] memory adapterList = vault.getAdapters();
        assertEq(adapterList.length, 1);
    }

    function test_setTargetWeights() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(adapter1);
        addrs[1] = address(adapter2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 4000;

        vault.setTargetWeights(addrs, weights);
        assertEq(vault.getAdapterWeight(address(adapter1)), 5000);
        assertEq(vault.getAdapterWeight(address(adapter2)), 4000);
    }

    function test_setTargetWeights_invalidSumReverts() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(adapter1);
        addrs[1] = address(adapter2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000; // 5000 + 5000 + 1000 buffer = 11000 != 10000

        vm.expectRevert(abi.encodeWithSelector(IZHYPEVault.WeightsSumInvalid.selector, 11000));
        vault.setTargetWeights(addrs, weights);
    }

    function test_pause() public {
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.stake{value: 1 ether}();
    }

    function test_unpause() public {
        vault.pause();
        vault.unpause();

        vm.prank(user1);
        uint256 minted = vault.stake{value: 1 ether}();
        assertGt(minted, 0);
    }

    // ==================== ACCESS CONTROL TESTS ====================

    function test_onlyAdmin_addAdapter() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.addAdapter(address(0xBEEF), 1000);
    }

    function test_onlyGuardian_pause() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    function test_onlyOperator_rebalance() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.rebalance();
    }

    // ==================== REBALANCE TESTS ====================

    function test_rebalance_deploysExcessBuffer() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // Simulate excess buffer by sending HYPE directly
        vm.deal(address(vault), 5 ether);

        uint256 bufferBefore = vault.getBufferBalance();
        vault.rebalance();
        uint256 bufferAfter = vault.getBufferBalance();

        // Buffer should decrease toward target
        assertLt(bufferAfter, bufferBefore);
    }

    // ==================== MULTI-USER TESTS ====================

    // ==================== CODEX REVIEW FIX TESTS ====================

    function test_claimWithdrawal_beforeDelayReverts() public {
        vm.startPrank(user1);
        vault.stake{value: 10 ether}();

        uint256 shares = vault.convertToShares(5 ether);
        zHYPE.approve(address(vault), shares);
        uint256 requestId = vault.requestWithdrawal(shares);
        vm.stopPrank();

        // Try to claim immediately (before 7-day delay)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ZHYPEVault.WithdrawalNotReady.selector, requestId));
        vault.claimWithdrawal(requestId);
    }

    function test_removeAdapter_withFundsReverts() public {
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // adapter1 has funds, removal should revert
        uint256 reserve = adapter1.getReserveInHYPE();
        assertGt(reserve, 0);
        vm.expectRevert(abi.encodeWithSelector(ZHYPEVault.AdapterHasFunds.selector, address(adapter1), reserve));
        vault.removeAdapter(address(adapter1));
    }

    function test_setBufferTargetWeight_tooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ZHYPEVault.BufferWeightTooHigh.selector, 10000));
        vault.setBufferTargetWeight(10000);
    }

    function test_setMinStakeAmount_tooLowReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ZHYPEVault.MinStakeTooLow.selector, 500));
        vault.setMinStakeAmount(500);
    }

    function test_reservedBuffer_trackedCorrectly() public {
        vm.startPrank(user1);
        vault.stake{value: 10 ether}();

        // Request queued withdrawal — buffer portion gets reserved
        uint256 shares = vault.convertToShares(5 ether);
        zHYPE.approve(address(vault), shares);
        vault.requestWithdrawal(shares);
        vm.stopPrank();

        // reservedBuffer should be > 0 (buffer portion was reserved)
        assertGt(vault.reservedBuffer(), 0);
        // pendingWithdrawalHYPE should track the liability
        assertGt(vault.pendingWithdrawalHYPE(), 0);
    }

    function test_activeTotalAssets_excludesLiabilities() public {
        // Two users stake so partial withdrawal doesn't drain all shares
        vm.prank(user1);
        vault.stake{value: 10 ether}();
        vm.prank(user2);
        vault.stake{value: 10 ether}();

        // user1 withdraws half
        vm.startPrank(user1);
        uint256 shares = vault.convertToShares(5 ether);
        zHYPE.approve(address(vault), shares);
        vault.requestWithdrawal(shares);
        vm.stopPrank();

        // Exchange rate for remaining holders should stay ~1:1
        uint256 assetsPerShare = vault.convertToAssets(1 ether);
        assertApproxEqRel(assetsPerShare, 1 ether, 0.05e18);
    }

    // ==================== MULTI-USER TESTS ====================

    function test_multiUser_fairShares() public {
        // User1 stakes 10 ether
        vm.prank(user1);
        vault.stake{value: 10 ether}();

        // Yield accrues: +2 ether (20%)
        vm.deal(address(adapter1), address(adapter1).balance + 2 ether);
        adapter1.accrueYield(2 ether);

        // User2 stakes 10 ether after yield
        vm.prank(user2);
        uint256 user2Shares = vault.stake{value: 10 ether}();

        // User2 should get fewer shares (since rate increased)
        uint256 user1Shares = zHYPE.balanceOf(user1);
        assertLt(user2Shares, user1Shares);

        // But their asset value should be ~10 ether
        uint256 user2Assets = vault.convertToAssets(user2Shares);
        assertApproxEqRel(user2Assets, 10 ether, 0.01e18);
    }
}
