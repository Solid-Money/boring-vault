// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract IPORFusionVaultDecoderAndSanitizer is BaseDecoderAndSanitizer {
    function requestShares(
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    function redeemFromRequest(
        uint256,
        address receiver_,
        address owner_
    ) external pure virtual returns (bytes memory addressesFound) {
        return abi.encodePacked(receiver_, owner_);
    }
}
