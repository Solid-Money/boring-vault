// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {YieldBasisDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Protocols/YieldBasisDecoderAndSanitizer.sol";

/// @notice soBTC on Ethereum: approve WBTC or cbBTC to a Yield Basis LT, deposit into it and withdraw from it.
///         The vault-manager reads its address from YIELDBASIS_DECODER_ADDRESS_ETHEREUM.
contract SolidYieldBasisDecoderAndSanitizer is BaseDecoderAndSanitizer, YieldBasisDecoderAndSanitizer {}
