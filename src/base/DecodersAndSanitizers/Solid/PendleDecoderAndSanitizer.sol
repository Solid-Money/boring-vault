// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PendleRouterDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract PendleDecoderAndSanitizer is BaseDecoderAndSanitizer, PendleRouterDecoderAndSanitizer {
    function swapExactPtForToken(
        address user,
        address market,
        uint256,
        DecoderCustomTypes.TokenOutput calldata output,
        DecoderCustomTypes.LimitOrderData calldata limit
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            user,
            market,
            output.tokenOut,
            output.tokenRedeemSy,
            output.pendleSwap,
            output.swapData.extRouter,
            _sanitizeLimitOrderData(limit)
        );
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256,
        DecoderCustomTypes.ApproxParams calldata,
        DecoderCustomTypes.TokenInput calldata input,
        DecoderCustomTypes.LimitOrderData calldata limit
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            receiver,
            market,
            input.tokenIn,
            input.tokenMintSy,
            input.pendleSwap,
            input.swapData.extRouter,
            _sanitizeLimitOrderData(limit)
        );
    }

    function exitPreExpToToken(
        address receiver,
        address market,
        uint256,
        uint256,
        uint256,
        DecoderCustomTypes.TokenOutput calldata output,
        DecoderCustomTypes.LimitOrderData calldata limit
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            receiver,
            market,
            output.tokenOut,
            output.tokenRedeemSy,
            output.pendleSwap,
            output.swapData.extRouter,
            _sanitizeLimitOrderData(limit)
        );
    }

    function exitPreExpToSy(
        address receiver,
        address market,
        uint256,
        uint256,
        uint256,
        uint256,
        DecoderCustomTypes.LimitOrderData calldata limit
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            receiver,
            market,
            _sanitizeLimitOrderData(limit)
        );
    }

    function exitPostExpToToken(
        address receiver,
        address market,
        uint256,
        uint256,
        DecoderCustomTypes.TokenOutput calldata output
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            receiver,
            market,
            output.tokenOut,
            output.tokenRedeemSy,
            output.pendleSwap,
            output.swapData.extRouter
        );
    }

    function exitPostExpToSy(
        address receiver,
        address market,
        uint256,
        uint256,
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver, market);
    }

    function redeemPyToToken(
        address receiver,
        address YT,
        uint256,
        DecoderCustomTypes.TokenOutput calldata output
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            receiver,
            YT,
            output.tokenOut,
            output.tokenRedeemSy,
            output.pendleSwap,
            output.swapData.extRouter
        );
    }
}
