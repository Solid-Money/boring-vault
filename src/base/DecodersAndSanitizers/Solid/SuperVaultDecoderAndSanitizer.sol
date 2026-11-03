// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC4626DecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";

/// @notice Superform V2 SuperVaults: ERC4626 deposits, ERC7540 asynchronous redeems with
///         cancellation. withdraw and redeem claim a fulfilled request; their third argument is
///         the controller, which ERC4626DecoderAndSanitizer already returns.
contract SuperVaultDecoderAndSanitizer is ERC4626DecoderAndSanitizer {
    //============================== SuperVault ===============================

    function requestRedeem(uint256, /*shares*/ address controller, address owner)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller, owner);
    }

    function cancelRedeemRequest(uint256, /*requestId*/ address controller)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller);
    }

    function claimCancelRedeemRequest(uint256, /*requestId*/ address receiver, address controller)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, controller);
    }
}
