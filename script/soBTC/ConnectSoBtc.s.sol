// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import {LayerZeroTeller} from "src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol";
import {SoBtcConfig, ILayerZeroEndpointSoBtc} from "./SoBtcConfig.sol";

/**
 * Peers this chain's soBTC teller with the other chain's, read from the other chain's record.
 * Run on both chains once both are deployed, before the handover (the deployer still owns the teller).
 *
 *   forge script script/soBTC/ConnectSoBtc.s.sol --rpc-url <mainnet|base> --private-key $PRIVATE_KEY --broadcast --slow
 */
contract ConnectSoBtc is SoBtcConfig {
    function run() external {
        BtcChain memory c = _chain();
        string memory own = vm.readFile(c.record);
        string memory peer = vm.readFile(c.peerRecord);
        require(
            vm.parseJsonUint(peer, ".chainId") == (c.eid == ETHEREUM_EID ? BASE_CHAIN_ID : ETHEREUM_CHAIN_ID),
            "Peer record is for the wrong chain"
        );
        LayerZeroTeller teller = LayerZeroTeller(payable(vm.parseJsonAddress(own, ".LayerZeroTeller")));
        address peerTeller = vm.parseJsonAddress(peer, ".LayerZeroTeller");

        // The DVN config DeploySoBtc set must still be in place before messages are allowed.
        SetConfigParam memory send = _uln(c.peerEid, c.confSend, c.dvnLow, c.dvnHigh);
        SetConfigParam memory recv = _uln(c.peerEid, c.confReceive, c.dvnLow, c.dvnHigh);
        ILayerZeroEndpointSoBtc endpoint = ILayerZeroEndpointSoBtc(LZ_ENDPOINT);
        require(
            keccak256(endpoint.getConfig(address(teller), c.sendLib, c.peerEid, ULN_CONFIG_TYPE))
                == keccak256(send.config),
            "Send ULN config missing"
        );
        require(
            keccak256(endpoint.getConfig(address(teller), c.receiveLib, c.peerEid, ULN_CONFIG_TYPE))
                == keccak256(recv.config),
            "Receive ULN config missing"
        );

        vm.startBroadcast();
        require(msg.sender == DEPLOYER, "Broadcast from the deployer 0x3B69");
        teller.addChain(c.peerEid, true, true, peerTeller, MESSAGE_GAS_LIMIT);
        vm.stopBroadcast();

        require(teller.peers(c.peerEid) == bytes32(uint256(uint160(peerTeller))), "Peer not set");
        console.log(string.concat("soBTC ", c.name, " teller peered with"), peerTeller);
    }
}
