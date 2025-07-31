// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PendleRouterDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract SolidDecoderAndSanitizer is PendleRouterDecoderAndSanitizer {
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
            _sanitizeLimitOrderData(limit)
        );
    }
}
