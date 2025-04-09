// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {INonFungiblePositionManager} from "src/interfaces/RawDataDecoderAndSanitizerInterfaces.sol";

import {Script, console} from "forge-std/Script.sol";

/// @dev Final working Uniswap V3 sanitizer

/*

    source .env && forge script script/POC/Deploy/DeploySanatizer.s.sol:DeployUniswapV3Sanitizer --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast

*/
contract UniswapV3Sanitizer {
    INonFungiblePositionManager internal immutable positionManager;

    constructor(address _positionManager) {
        positionManager = INonFungiblePositionManager(_positionManager);
    }

    function mint(
        DecoderCustomTypes.MintParams calldata params
    ) external view returns (bytes memory) {
        return abi.encodePacked(params.token0, params.token1, params.recipient);
    }

    function increaseLiquidity(
        DecoderCustomTypes.IncreaseLiquidityParams calldata params
    ) external view returns (bytes memory) {
        address owner = positionManager.ownerOf(params.tokenId);
        (
            ,
            address operator,
            address token0,
            address token1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = positionManager.positions(params.tokenId);
        return abi.encodePacked(operator, token0, token1, owner);
    }

    function decreaseLiquidity(
        DecoderCustomTypes.DecreaseLiquidityParams calldata params
    ) external view returns (bytes memory) {
        address owner = positionManager.ownerOf(params.tokenId);
        return abi.encodePacked(owner);
    }

    function collect(
        DecoderCustomTypes.CollectParams calldata params
    ) external view returns (bytes memory) {
        address owner = positionManager.ownerOf(params.tokenId);
        return abi.encodePacked(params.recipient, owner);
    }

    function exactInput(
        DecoderCustomTypes.ExactInputParams calldata params
    ) external pure returns (bytes memory) {
        uint256 chunkSize = 23;
        uint256 pathLength = params.path.length;
        require(pathLength % chunkSize == 20, "Bad path format");
        uint256 numAddresses = 1 + (pathLength / chunkSize);

        bytes memory result;
        uint256 index;
        for (uint256 i = 0; i < numAddresses; ++i) {
            result = abi.encodePacked(result, params.path[index:index + 20]);
            index += chunkSize;
        }

        return abi.encodePacked(result, params.recipient);
    }

    function burn(uint256 tokenId) external view returns (bytes memory) {
        address owner = positionManager.ownerOf(tokenId);
        return abi.encodePacked(owner);
    }
}

contract DeployUniswapV3Sanitizer is Script {
    function run() external {
        vm.startBroadcast();

        address positionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

        UniswapV3Sanitizer sanitizer = new UniswapV3Sanitizer(positionManager);
        console.log("Sanitizer deployed at:", address(sanitizer));

        vm.stopBroadcast();
    }
}
