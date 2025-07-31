// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {EthereumTeller} from "src/poc/EthereumTeller.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/Test.sol";

/*
    source .env && forge script script/POC/Deploy/DeployEthereumTeller.s.sol:DeployEthereumTeller --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DeployEthereumTeller is Script {
    function run() external {
        vm.startBroadcast();

        address wethAddress = vm.envAddress("WETH");
        address payable vault = payable(vm.envAddress("VAULT"));

        // Deploy EthereumTeller
        EthereumTeller teller = new EthereumTeller(
            wethAddress,
            BoringVault(vault)
        );
        console.log("EthereumTeller deployed at:", address(teller));

        vm.stopBroadcast();
    }
}
