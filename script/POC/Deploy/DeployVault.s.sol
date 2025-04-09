// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "@forge-std/Test.sol";

/**
    source .env && forge script script/POC/Deploy/DeployVault.s.sol:DeployVault --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DeployVault is Script {
    function run() external {
        vm.startBroadcast();

        address deployer = vm.envAddress("DEPLOYER");

        BoringVault vault = new BoringVault(deployer, "Fuse WETH", "fWETH", 18);
        console.log("fWETH Vault deployed at:", address(vault));
        vm.stopBroadcast();
    }
}
