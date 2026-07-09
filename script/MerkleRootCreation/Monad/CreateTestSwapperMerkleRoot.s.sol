
// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {ERC4626} from "@solmate/tokens/ERC4626.sol";
import {MerkleTreeHelper} from "test/resources/MerkleTreeHelper/MerkleTreeHelper.sol";
import "forge-std/Script.sol";

/**
 *  source .env && forge script script/MerkleRootCreation/Monad/CreateTestSwapperMerkleRoot.s.sol --rpc-url $MONAD_RPC_URL --gas-limit 1000000000000000000
 */
contract CreateTestSwapperMerkleRoot is Script, MerkleTreeHelper {
    using FixedPointMathLib for uint256;

    //standard
    address public boringVault = 0x0Fc760EEbEFbF5FE3B452A9a52325c4376FEADFA;
    address public rawDataDecoderAndSanitizer = 0xaBa0791af163d1A4EE8075500763B5b03b477047;
    address public managerAddress = 0x1AE3346BC6d3267b860De524D5E38E19679A1DB0;
    address public accountantAddress = 0xD1135B891143d3c5DfE158C6b4961937a27b8AE4;
    

    function setUp() external {}

    /**
     * @notice Uncomment which script you want to run.
     */
    function run() external {
        generateStrategistMerkleRoot();
    }

    function generateStrategistMerkleRoot() public {
        setSourceChainName(monad);
        setAddress(false, monad, "boringVault", boringVault);
        setAddress(false, monad, "managerAddress", managerAddress);
        setAddress(false, monad, "accountantAddress", accountantAddress);
        setAddress(false, monad, "rawDataDecoderAndSanitizer", rawDataDecoderAndSanitizer);

        ManageLeaf[] memory leafs = new ManageLeaf[](32);

        // ========================== Swapper ==========================
        address swapper = 0x6b01D470d3c2E57070E2DCC23a2576bAa4e49F9b;
        address[][] memory pairs = new address[][](2);
        pairs[0] = new address[](2);
        pairs[0][0] = getAddress(sourceChain, "WETH");
        pairs[0][1] = getAddress(sourceChain, "USDC");

        pairs[1] = new address[](2);
        pairs[1][0] = getAddress(sourceChain, "mUSD");
        pairs[1][1] = getAddress(sourceChain, "USDC");

        SwapKind[] memory kind = new SwapKind[](2);
        kind[0] = SwapKind.BuyAndSell;
        kind[1] = SwapKind.BuyAndSell;

        _addBoringSwapperLeafs(leafs, swapper, pairs, kind);

        // ========================== Verify ==========================
        _verifyDecoderImplementsLeafsFunctionSelectors(leafs);

        bytes32[][] memory manageTree = _generateMerkleTree(leafs);

        string memory filePath = "./leafs/Monad/TestSwapperMerkleRoot.json";

        _generateLeafs(filePath, leafs, manageTree[manageTree.length - 1][0], manageTree);

    }
}
