// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {VedaVaultDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/VedaVaultDecoderAndSanitizer.sol";

/// @notice soBTC on Ethereum: WBTC into ether.fi Liquid BTC (liquidBTC) through its teller, and out in two queue
///         hops, liquidBTC -> eBTC on the liquidBTC queue, then eBTC -> WBTC on the eBTC queue. The vault-manager
///         reads its address from LIQUIDBTC_DECODER_ADDRESS_ETHEREUM.
contract SolidLiquidBTCDecoderAndSanitizer is BaseDecoderAndSanitizer, VedaVaultDecoderAndSanitizer {}
