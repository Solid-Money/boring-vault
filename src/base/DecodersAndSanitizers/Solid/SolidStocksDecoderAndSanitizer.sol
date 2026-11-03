// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {SuperVaultDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/SuperVaultDecoderAndSanitizer.sol";
import {MerklDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/MerklDecoderAndSanitizer.sol";

/// @notice Decoder for the Solid stock vaults on Base (soAAPL, soNVDA, ...): each one deposits its
///         B20 stock token into the matching Superform SuperVault and claims that vault's Merkl rewards.
contract SolidStocksDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    SuperVaultDecoderAndSanitizer,
    MerklDecoderAndSanitizer
{}
