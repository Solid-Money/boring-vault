// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract rUSDDecoderAndSanitizer is BaseDecoderAndSanitizer {
    function mintStablecoin(
        address user,
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(user);
    }

    function mintStablecoin(
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    function redeem(
        address user,
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(user);
    }

    function redeem(
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }
}
