// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract InfiniFiDecoderAndSanitizer is BaseDecoderAndSanitizer {
    function mintAndLock(
        address _to,
        uint256,
        uint32
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_to);
    }

    function startUnwinding(
        uint256,
        uint32
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    function withdraw(
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    function redeem(
        address _to,
        uint256,
        uint256
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_to);
    }
}
