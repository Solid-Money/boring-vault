// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {Script, console} from "lib/forge-std/src/Script.sol";

/*
    source .env && forge script script/POC/StrategyManagement.s.sol:ManageUniswapStrategy --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract ManageUniswapStrategy is Script {
    function run() external {
        vm.startBroadcast();

        // === Constants ===
        address managerAddr = 0x621F1aEC663604BEdc5A7648cb85ddDFD0CE124D;
        address sanitizer = 0x2d2f6D3bB89650B7CeB5E77Ad3dDb6Dc8BfCFCBF;
        address uniswapV3Manager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

        address strategist = vm.envAddress("DEPLOYER");

        bytes32 newRoot = 0x05f35f96e30f8fa5f890c98b67fe8ed33382c0228e800a8ac727abe910ffd94e;
        ManagerWithMerkleVerification(managerAddr).setManageRoot(
            strategist,
            newRoot
        );
        console.log("New Merkle root set for strategist");

        bytes32[][] memory proofs = new bytes32[][](1);
        bytes32[] memory proof = new bytes32[](3);
        address[] memory sanitizers = new address[](1);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        // === 2. Merkle proof for UniswapV3Manager::mint
        proof[
            0
        ] = 0x2165ab8142319d8e04619cc8c267ec04520dc836339da253e918bb9f3fe2e54d;
        proof[
            1
        ] = 0xc2e3dfa46c061f592f7a2bc233b36d0b8c2fd839ba765a5c36ef75bfa5ebc558;
        proof[
            2
        ] = 0xfd8b3ecaac0138d70e4b04ab50313c8c21555c17f6fc9b27aa9236ea184b7072;
        proofs[0] = proof;

        // === 3. Sanitizers ===
        sanitizers[0] = sanitizer;

        // === 4. Targets ===
        targets[0] = uniswapV3Manager;

        // === 5. Calldata for mint
        datas[
            0
        ] = hex"88316456000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000000000000bb8fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbc896fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbc8d200000000000000000000000000000000000000000000000000005af3107a40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c85d01b40a2152be20862deb331ecba0fd6d6910000000000000000000000000000000000000000000000000000000067f6390f";

        // === 6. ETH values
        values[0] = 0;

        // === 7. Execute
        ManagerWithMerkleVerification(managerAddr)
            .manageVaultWithMerkleVerification(
                proofs,
                sanitizers,
                targets,
                datas,
                values
            );

        console.log("Uniswap V3 mint() executed via manager");

        vm.stopBroadcast();
    }
}
