// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

import {Script, console} from "forge-std/Script.sol";

/*
  source .env && forge script script/POC/DepositAsOwner.s.sol:DepositAsOwner --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DepositAsOwner is Script {
    function run() external {
        vm.startBroadcast();

        address payable VAULT = payable(vm.envAddress("VAULT"));
        address WETH = vm.envAddress("WETH");
        address SENDER = vm.envAddress("DEPLOYER");
        uint256 amount = 0.0001 ether;

        BoringVault vault = BoringVault(VAULT);
        ERC20 weth = ERC20(WETH);

        // Approve the vault to pull funds
        weth.approve(VAULT, amount);

        // Use enter() to mint vault shares to sender
        vault.enter(SENDER, weth, amount, SENDER, amount);

        console.log("Minted", amount, "shares for", SENDER);

        vm.stopBroadcast();
    }
}
