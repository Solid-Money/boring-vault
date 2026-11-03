// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {CCTPDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/CCTPDecoderAndSanitizer.sol";

/// @notice soUSD on Base and Ethereum: approve USDC to Circle's TokenMessengerV2 and burn it towards the
///         other chain's vault with depositForBurn (CCTP V2). The strategist submits the mint on the
///         destination itself, so receiveMessage needs no leaf. Deployed through CREATE2 so both chains
///         share one address.
contract SolidCCTPDecoderAndSanitizer is BaseDecoderAndSanitizer, CCTPDecoderAndSanitizer {
    error SolidCCTPDecoderAndSanitizer__MintRecipientNotEvm();
    error SolidCCTPDecoderAndSanitizer__DestinationCallerNotEvm();

    //============================== TOKEN MESSENGER V2 ===============================

    /// @dev As CCTPDecoderAndSanitizer, but the recipient and caller are packed as addresses, so their
    ///      upper 12 bytes must be zero: otherwise two different bytes32 values would match one leaf.
    function depositForBurn(
        uint256, /*amount*/
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256, /*maxFee*/
        uint32 /*minFinalityThreshold*/
    ) external pure override returns (bytes memory addressesFound) {
        if (uint256(mintRecipient) >> 160 != 0) {
            revert SolidCCTPDecoderAndSanitizer__MintRecipientNotEvm();
        }
        if (uint256(destinationCaller) >> 160 != 0) {
            revert SolidCCTPDecoderAndSanitizer__DestinationCallerNotEvm();
        }
        addressesFound = abi.encodePacked(
            address(uint160(destinationDomain)),
            address(uint160(uint256(mintRecipient))),
            burnToken,
            address(uint160(uint256(destinationCaller)))
        );
    }
}
