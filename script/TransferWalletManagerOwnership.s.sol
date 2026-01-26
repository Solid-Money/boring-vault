// script/DeployWalletManager.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TransferWalletManagerOwnership is Script {
    function run() external {
        address walletManager = vm.envAddress("WALLET_MANAGER");
        address owner = vm.envAddress("OWNER");
        
        vm.startBroadcast();
        
        // call setOperator
        (bool success,) = walletManager.call(
            abi.encodeWithSelector(Ownable.transferOwnership.selector, owner)
        );
        require(success, "Failed to set owner");
        
        vm.stopBroadcast();
    }
}