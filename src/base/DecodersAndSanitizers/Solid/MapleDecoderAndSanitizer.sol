// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {SyrupDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/SyrupDecoderAndSanitizer.sol";
import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract MapleDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    SyrupDecoderAndSanitizer
{
    function authorizeAndDeposit(
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32,
        uint256,
        bytes32
    ) external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }
}
