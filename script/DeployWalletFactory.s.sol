// script/DeployWalletFactory.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {WalletFactory} from "src/fuse/WalletManager/WalletFactory.sol";

contract DeployWalletFactory is Script {
    // Nick's Factory address (exists on most chains)
    address constant SINGLETON_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    
    function run() external {
        address manager = vm.envAddress("WALLET_MANAGER");
        bytes32 salt = vm.envBytes32("DEPLOYMENT_SALT");
        
        bytes memory bytecode = abi.encodePacked(
            type(WalletFactory).creationCode,
            abi.encode(manager)
        );
        
        // Predict address
        address predicted = getCreate2Address(salt, bytecode);
        console.log("Predicted WalletFactory address:", predicted);
        
        vm.startBroadcast();
        
        // Deploy via singleton factory
        (bool success, bytes memory data) = SINGLETON_FACTORY.call(
            abi.encodePacked(salt, bytecode)
        );
        require(success, "Deployment failed");
        
        address deployed;
        require(data.length == 20, "Invalid return data");
        assembly {
            deployed := shr(96, mload(add(data, 0x20)))
        }
        console.log("Deployed WalletFactory at:", deployed);
        require(deployed == predicted, "Address mismatch");
        
        vm.stopBroadcast();
    }
    
    function getCreate2Address(bytes32 salt, bytes memory bytecode) 
        public 
        pure 
        returns (address) 
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                SINGLETON_FACTORY,
                salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }
}