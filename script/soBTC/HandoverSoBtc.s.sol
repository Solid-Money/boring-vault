// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import {Auth} from "@solmate/auth/Auth.sol";
import {LayerZeroTeller} from "src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol";
import {SoBtcConfig, ILayerZeroEndpointSoBtc} from "./SoBtcConfig.sol";

/**
 * Hands one chain's soBTC contracts to that chain's Safe: the teller's LayerZero delegate first (a
 * delegate can change DVNs and so forge share mints), then ownership of every contract in the record
 * (seven on Ethereum; five on Base, which has no queue or solver).
 * After it, the deployer has no access to soBTC on that chain.
 *
 *   forge script script/soBTC/HandoverSoBtc.s.sol --rpc-url <mainnet|base> --private-key $PRIVATE_KEY --broadcast --slow
 */
contract HandoverSoBtc is SoBtcConfig {
    function run() external {
        BtcChain memory c = _chain();
        string memory json = vm.readFile(c.record);
        bool withQueue = vm.keyExistsJson(json, ".BoringQueue");
        require(withQueue == c.withdrawals, "Record does not match the chain's withdrawal setup");
        address[] memory owned = new address[](withQueue ? 7 : 5);
        owned[0] = vm.parseJsonAddress(json, ".RolesAuthority");
        owned[1] = vm.parseJsonAddress(json, ".BoringVault");
        owned[2] = vm.parseJsonAddress(json, ".Accountant");
        owned[3] = vm.parseJsonAddress(json, ".LayerZeroTeller");
        owned[4] = vm.parseJsonAddress(json, ".Manager");
        if (withQueue) {
            owned[5] = vm.parseJsonAddress(json, ".BoringQueue");
            owned[6] = vm.parseJsonAddress(json, ".BoringSolver");
        }
        address teller = owned[3];
        ILayerZeroEndpointSoBtc endpoint = ILayerZeroEndpointSoBtc(LZ_ENDPOINT);
        require(LayerZeroTeller(payable(teller)).peers(c.peerEid) != bytes32(0), "Run ConnectSoBtc first");

        vm.startBroadcast();
        require(msg.sender == DEPLOYER, "Broadcast from the deployer 0x3B69");
        if (endpoint.delegates(teller) != c.safe) LayerZeroTeller(payable(teller)).setDelegate(c.safe);
        for (uint256 i; i < owned.length; i++) {
            if (Auth(owned[i]).owner() == DEPLOYER) Auth(owned[i]).transferOwnership(c.safe);
        }
        vm.stopBroadcast();

        require(endpoint.delegates(teller) == c.safe, "Delegate not handed over");
        for (uint256 i; i < owned.length; i++) {
            require(Auth(owned[i]).owner() == c.safe, "Ownership not handed over");
        }
        console.log(string.concat("soBTC ", c.name, ": delegate and ownership now with"), c.safe);
    }
}
