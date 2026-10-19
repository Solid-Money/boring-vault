// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {CrossChainTokenServiceDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Protocols/CrossChainTokenServiceDecoderAndSanitizer.sol";

/// @notice soEUR on Base and Ethereum: approve EURC to its TokenManager and move it between the two
///         vaults through Circle's CrossChainTokenService. Deployed through CREATE2 so both chains share
///         one address.
contract SolidCrossChainTokenDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    CrossChainTokenServiceDecoderAndSanitizer
{}
