// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer, DecoderCustomTypes} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Circle's CCTP for non-USDC tokens (CrossChainTokenService). The vault approves the token's
///         TokenManager, not the service, so that leaf goes through BaseDecoderAndSanitizer.approve.
abstract contract CrossChainTokenServiceDecoderAndSanitizer is BaseDecoderAndSanitizer {
    error CrossChainTokenServiceDecoderAndSanitizer__DestinationAddressNotEvm();
    error CrossChainTokenServiceDecoderAndSanitizer__DestinationCallerNotEvm();
    error CrossChainTokenServiceDecoderAndSanitizer__HooksNotSupported();

    //============================== CROSS CHAIN TOKEN SERVICE ===============================

    function crossChainTransfer(
        bytes32 tokenId,
        uint256, /*amount*/
        uint32 destinationDomain,
        bytes calldata destinationAddress,
        bytes32 destinationCaller,
        uint32, /*minFinalityThreshold*/
        DecoderCustomTypes.CrossChainTokenClaim calldata claim,
        bool autoExecuteHookData,
        bytes calldata hookData
    ) external pure virtual returns (bytes memory addressesFound) {
        // EVM destinations take the raw 20-byte address.
        if (destinationAddress.length != 20) {
            revert CrossChainTokenServiceDecoderAndSanitizer__DestinationAddressNotEvm();
        }
        // The caller is packed as an address below, so its upper 12 bytes must be zero.
        if (uint256(destinationCaller) >> 160 != 0) {
            revert CrossChainTokenServiceDecoderAndSanitizer__DestinationCallerNotEvm();
        }
        if (autoExecuteHookData || hookData.length != 0) {
            revert CrossChainTokenServiceDecoderAndSanitizer__HooksNotSupported();
        }

        // tokenId is 32 bytes, so it takes two address slots: bytes 0..19 and bytes 12..31.
        addressesFound = abi.encodePacked(
            address(bytes20(tokenId)),
            address(uint160(uint256(tokenId))),
            address(uint160(destinationDomain)),
            address(bytes20(destinationAddress)),
            address(uint160(uint256(destinationCaller))),
            claim.refundAddress
        );
    }
}
