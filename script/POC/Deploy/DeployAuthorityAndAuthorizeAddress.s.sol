// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {SimpleAuthority} from "src/poc/SimpleAuthority.sol";

import {Script, console} from "@forge-std/Script.sol";

/*
    forge script script/POC/Deploy/DeployAuthorityAndAuthorizeAddress.s.sol:DeployAuthorityAndAuthorizeAddress --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DeployAuthorityAndAuthorizeAddress is Script {
    function run() external {
        vm.startBroadcast();

        // === Load from .env ===
        address addressToAuthorize = address(0); // replace with the address you want to authorize
        address vault = vm.envAddress("VAULT");

        // === 1. Deploy authority
        SimpleAuthority authority = new SimpleAuthority();
        console.log("SimpleAuthority deployed:", address(authority));

        // === 2. Compute selector for manage(address,bytes,uint256)
        bytes4 manageSelector = bytes4(
            keccak256("manage(address,bytes,uint256)")
        );

        // === 3. Grant permission to addressToAuthorize to call vault.manage(...)
        authority.setPermission(
            addressToAuthorize,
            vault,
            manageSelector,
            true
        );
        console.log("Permission granted to addressToAuthorize");

        // === 4. Set authority on the vault
        IBoringVault(vault).setAuthority(address(authority));
        console.log("Vault authority updated");

        vm.stopBroadcast();
    }
}
