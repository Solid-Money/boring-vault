// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {Script, console} from "forge-std/Script.sol";

contract WithdrawScript is Script {
    function run() external {
        vm.startBroadcast();

        address VAULT = vm.envAddress("VAULT");
        uint256 SHARES = 100 * 1e18;

        BoringVault vault = BoringVault(VAULT);

        // Withdraw tokens from the vault
        vault.withdraw(SHARES, msg.sender);

        console.log("Withdrew", SHARES, "shares from vault at", VAULT);

        vm.stopBroadcast();
    }
}
