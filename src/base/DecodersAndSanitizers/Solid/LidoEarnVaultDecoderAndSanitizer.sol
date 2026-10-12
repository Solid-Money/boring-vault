// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract LidoEarnVaultDecoderAndSanitizer is BaseDecoderAndSanitizer {
    function redeem(
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }

    function claim(
        address receiver,
        uint32[] calldata
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
        return addressesFound;
    }

    function deposit(
        uint224,
        address,
        bytes32[] calldata
    ) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }
}
