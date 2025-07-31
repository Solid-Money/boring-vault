// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {PancakeSwapV3DecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Protocols/PancakeSwapV3DecoderAndSanitizer.sol";

contract PancakeSwapV3FullDecoderAndSanitizer is PancakeSwapV3DecoderAndSanitizer, BaseDecoderAndSanitizer {
    constructor(address _pancakeSwapV3NonFungiblePositionManager, address _pancakeSwapV3MasterChef)
        PancakeSwapV3DecoderAndSanitizer(_pancakeSwapV3NonFungiblePositionManager, _pancakeSwapV3MasterChef)
    {}
}
