// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {wSwellUnwrappingDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/wSwellUnwrappingDecoderAndSanitizer.sol"; 

contract FullRewardTokenUnwrappingDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    wSwellUnwrappingDecoderAndSanitizer
{}
