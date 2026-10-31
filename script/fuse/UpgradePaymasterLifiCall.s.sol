// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

/**
 * @notice Upgrades a live BridgePaymaster to the implementation with `lifiCall` and opens it for
 *         LI.FI's Stargate swaps between Fuse and Ethereum, Base and BNB Chain: registers LI.FI's
 *         diamond, its destinations and a per-swap cap on the native fee.
 * @dev The chain is picked from the RPC: Fuse's paymaster sends to the other three, theirs send to
 *      Fuse. Run by the proxy's owner, it deploys the implementation and sends every call; run by
 *      anyone else, it deploys the implementation and prints the owner's calls to make.
 *
 *      forge script script/fuse/UpgradePaymasterLifiCall.s.sol --rpc-url base \
 *        --account <owner> --broadcast --verify
 *
 *      Simulate first, as the owner, without a key:
 *      forge script script/fuse/UpgradePaymasterLifiCall.s.sol --rpc-url base --sender <owner>
 */
contract UpgradePaymasterLifiCall is Script {
    address internal constant DIAMOND = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
    address internal constant FUSE_PAYMASTER = 0x8D5333d3d9683D4D67F329027F0f5d4057f3306b;
    address internal constant TO_FUSE_PAYMASTER = 0xC4F4bb4CD9C2098Dd1Eb11e0055FD0E212c967fc;

    uint32 internal constant FUSE_EID = 30138;
    uint32 internal constant ETHEREUM_EID = 30101;
    uint32 internal constant BASE_EID = 30184;
    uint32 internal constant BNB_EID = 30102;

    function run() external {
        (BridgePaymaster paymaster, uint32[] memory destinations, uint256 cap) = _network();
        address owner = paymaster.owner();

        vm.startBroadcast();
        address implementation = address(new BridgePaymaster());
        vm.stopBroadcast();
        console2.log("Implementation:", implementation);

        bytes[] memory calls = new bytes[](3 + destinations.length);
        calls[0] = abi.encodeCall(paymaster.upgradeToAndCall, (implementation, ""));
        calls[1] = abi.encodeCall(paymaster.setTarget, (DIAMOND, BridgePaymaster.TargetKind.LIFI_DIAMOND, 0));
        calls[2] = abi.encodeCall(paymaster.setMaxSponsoredAmount, (DIAMOND, cap));
        for (uint256 i; i < destinations.length; i++) {
            calls[3 + i] = abi.encodeCall(paymaster.setRoute, (DIAMOND, destinations[i], true));
        }

        if (msg.sender != owner) {
            console2.log("Not the owner. The owner sends each of these to", address(paymaster));
            console2.log("Owner:", owner);
            for (uint256 i; i < calls.length; i++) {
                console2.logBytes(calls[i]);
            }
            return;
        }

        vm.startBroadcast();
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory result) = address(paymaster).call(calls[i]);
            if (!ok) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }
        vm.stopBroadcast();

        require(uint8(paymaster.targetKind(DIAMOND)) == uint8(BridgePaymaster.TargetKind.LIFI_DIAMOND), "diamond");
        require(paymaster.maxSponsoredAmount(DIAMOND) == cap, "cap");
        for (uint256 i; i < destinations.length; i++) {
            require(paymaster.allowedDstEid(DIAMOND, destinations[i]), "route");
        }
        console2.log("Upgraded and opened for LI.FI:", address(paymaster));
    }

    /// @dev The cap is several times today's fee, so a busier LayerZero still clears it while one
    ///      call can never spend much.
    function _network() internal view returns (BridgePaymaster, uint32[] memory, uint256) {
        uint32[] memory destinations;
        if (block.chainid == 122) {
            destinations = new uint32[](3);
            (destinations[0], destinations[1], destinations[2]) = (ETHEREUM_EID, BASE_EID, BNB_EID);
            // Today ~157-220 FUSE a send.
            return (BridgePaymaster(payable(FUSE_PAYMASTER)), destinations, 1_000 ether);
        }
        destinations = new uint32[](1);
        destinations[0] = FUSE_EID;
        // Today ~0.00054 ETH and ~0.0018 BNB a send.
        if (block.chainid == 1 || block.chainid == 8453) {
            return (BridgePaymaster(payable(TO_FUSE_PAYMASTER)), destinations, 0.003 ether);
        }
        if (block.chainid == 56) return (BridgePaymaster(payable(TO_FUSE_PAYMASTER)), destinations, 0.01 ether);
        revert("Unsupported chain");
    }
}
