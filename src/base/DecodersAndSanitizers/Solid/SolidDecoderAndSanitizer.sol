// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PendleDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/PendleDecoderAndSanitizer.sol";
import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {OFTDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/OFTDecoderAndSanitizer.sol";
import {ERC4626DecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";
import {IPORFusionVaultDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/IPORFusionVaultDecoderAndSanitizer.sol";
import {rUSDDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/rUSDDecoderAndSanitizer.sol";
import {OneInchDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import {AutoFinanceDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/AutoFinanceDecoderAndSanitizer.sol";

contract SolidDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    PendleDecoderAndSanitizer,
    OFTDecoderAndSanitizer,
    ERC4626DecoderAndSanitizer,
    IPORFusionVaultDecoderAndSanitizer,
    rUSDDecoderAndSanitizer,
    OneInchDecoderAndSanitizer,
    AutoFinanceDecoderAndSanitizer
{}
