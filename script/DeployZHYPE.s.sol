// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/lst/ZHYPE.sol";
import "../contracts/lst/ZHYPEVault.sol";
import "../contracts/lst/ZHYPEWithdrawalQueue.sol";
import "../contracts/lst/adapters/KHYPEAdapter.sol";

contract DeployZHYPE is Script {
    // HyperEVM Mainnet addresses
    address constant KINETIQ_STAKING_MANAGER = 0x393D0B87Ed38fc779FD9611144aE649BA6082109;
    address constant KINETIQ_ACCOUNTANT = 0x9209648Ec9D448EF57116B73A2f081835643dc7A;
    address constant KHYPE_TOKEN = 0xfD739d4e423301CE9385c1fb8850539D657C296D;

    uint256 constant WITHDRAWAL_DELAY = 7 days;
    uint256 constant KHYPE_WEIGHT = 6000; // 60%
    uint256 constant BUFFER_WEIGHT = 1000; // 10%
    // stHYPE weight would be 3000 (30%) — added separately

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy ZHYPE token
        ZHYPE zHYPEImpl = new ZHYPE();
        ERC1967Proxy zHYPEProxy = new ERC1967Proxy(
            address(zHYPEImpl),
            abi.encodeCall(ZHYPE.initialize, (deployer))
        );
        ZHYPE zHYPE = ZHYPE(address(zHYPEProxy));
        console.log("ZHYPE Token:", address(zHYPE));

        // 2. Deploy WithdrawalQueue
        ZHYPEWithdrawalQueue queueImpl = new ZHYPEWithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImpl),
            abi.encodeCall(ZHYPEWithdrawalQueue.initialize, (deployer, WITHDRAWAL_DELAY))
        );
        ZHYPEWithdrawalQueue queue = ZHYPEWithdrawalQueue(address(queueProxy));
        console.log("WithdrawalQueue:", address(queue));

        // 3. Deploy Vault
        ZHYPEVault vaultImpl = new ZHYPEVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(ZHYPEVault.initialize, (address(zHYPE), address(queue), deployer))
        );
        ZHYPEVault vault = ZHYPEVault(payable(address(vaultProxy)));
        console.log("ZHYPEVault:", address(vault));

        // 4. Deploy KHYPEAdapter
        KHYPEAdapter kAdapterImpl = new KHYPEAdapter();
        ERC1967Proxy kAdapterProxy = new ERC1967Proxy(
            address(kAdapterImpl),
            abi.encodeCall(KHYPEAdapter.initialize, (
                KINETIQ_STAKING_MANAGER,
                KINETIQ_ACCOUNTANT,
                KHYPE_TOKEN,
                deployer
            ))
        );
        KHYPEAdapter kAdapter = KHYPEAdapter(payable(address(kAdapterProxy)));
        console.log("KHYPEAdapter:", address(kAdapter));

        // 5. Configure roles
        // Grant MINTER_ROLE on ZHYPE to Vault
        zHYPE.grantRole(zHYPE.MINTER_ROLE(), address(vault));

        // Grant VAULT_ROLE on WithdrawalQueue to Vault
        queue.grantRole(queue.VAULT_ROLE(), address(vault));

        // Grant VAULT_ROLE on KHYPEAdapter to Vault
        kAdapter.grantRole(kAdapter.VAULT_ROLE(), address(vault));

        // 6. Register adapter in Vault
        vault.addAdapter(address(kAdapter), KHYPE_WEIGHT);
        vault.setBufferTargetWeight(BUFFER_WEIGHT);

        vm.stopBroadcast();

        console.log("--- Deployment Complete ---");
        console.log("Deployer:", deployer);
    }
}
