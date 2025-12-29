// script/DeployWalletManager.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {WalletManager} from "src/fuse/WalletManager/WalletManager.sol";

contract UpdateWalletManagerOperator is Script {
    function run() external {
        address walletManager = vm.envAddress("WALLET_MANAGER");
        address operator = vm.envAddress("OPERATOR");
        
        vm.startBroadcast();
        
        // call setOperator
        (bool success,) = walletManager.call(
            abi.encodeWithSelector(WalletManager.setOperator.selector, operator)
        );
        require(success, "Failed to set operator");
        
        vm.stopBroadcast();
    }
}