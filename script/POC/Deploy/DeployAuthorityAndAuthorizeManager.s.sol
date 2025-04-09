// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Script, console} from "forge-std/Script.sol";
import {Authority} from "@solmate/auth/Auth.sol";

interface IBoringVault {
    function setAuthority(address) external;
}

interface ISimpleAuthority is Authority {
    function setPermission(
        address user,
        address target,
        bytes4 funcSig,
        bool allowed
    ) external;
}

contract SimpleAuthority is Authority {
    mapping(address => mapping(address => mapping(bytes4 => bool)))
        public permissions;

    function canCall(
        address user,
        address target,
        bytes4 functionSig
    ) external view override returns (bool) {
        return permissions[user][target][functionSig];
    }

    function setPermission(
        address user,
        address target,
        bytes4 functionSig,
        bool allowed
    ) external {
        // you can add an owner check here if desired
        permissions[user][target][functionSig] = allowed;
    }
}

/*

    forge script script/POC/Deploy/DeployAuthorityAndAuthorizeManager.s.sol:DeployAuthorityAndAuthorizeManager --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast

*/
contract DeployAuthorityAndAuthorizeManager is Script {
    function run() external {
        vm.startBroadcast();

        // === Load from .env ===
        address manager = vm.envAddress("MANAGER");
        address vault = vm.envAddress("VAULT");

        // === 1. Deploy authority
        SimpleAuthority authority = new SimpleAuthority();
        console.log("SimpleAuthority deployed:", address(authority));

        // === 2. Compute selector for manage(address,bytes,uint256)
        bytes4 manageSelector = bytes4(
            keccak256("manage(address,bytes,uint256)")
        );

        // === 3. Grant permission to manager to call vault.manage(...)
        authority.setPermission(manager, vault, manageSelector, true);
        console.log("Permission granted to manager");

        // === 4. Set authority on the vault
        IBoringVault(vault).setAuthority(address(authority));
        console.log("Vault authority updated");

        vm.stopBroadcast();
    }
}
