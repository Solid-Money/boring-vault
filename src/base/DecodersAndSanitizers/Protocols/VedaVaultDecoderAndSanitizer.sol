// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";

/// @notice Another team's Veda BoringVault held as a strategy (e.g. ether.fi Liquid BTC): deposit through its
///         teller, and exit through its BoringOnChainQueue. Approving the asset to the vault, and the shares to
///         the queue, goes through BaseDecoderAndSanitizer.approve.
abstract contract VedaVaultDecoderAndSanitizer is BaseDecoderAndSanitizer {
    //============================== TELLER ===============================

    /// @dev TellerWithMultiAssetSupport.deposit(depositAsset, depositAmount, minimumMint). The shares are minted
    ///      to the caller, so only the asset is checked.
    function deposit(address depositAsset, uint256, /*depositAmount*/ uint256 /*minimumMint*/ )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(depositAsset);
    }

    //============================== BORING ON-CHAIN QUEUE ===============================

    /// @dev requestOnChainWithdraw(assetOut, amountOfShares, discount, secondsToDeadline). The request's user,
    ///      who the solver pays, is the caller, so only the asset is checked. The queue bounds the discount.
    function requestOnChainWithdraw(address assetOut, uint128, uint16, uint24)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(assetOut);
    }

    /// @dev The queue only lets the request's user cancel it, and returns the shares to that user.
    function cancelOnChainWithdraw(DecoderCustomTypes.OnChainWithdraw memory request)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(request.user, request.assetOut);
    }

    /// @dev Cancels the request (its user only) and queues the same shares again for the same user and asset,
    ///      priced at the current rate. Used once a request is past its deadline.
    function replaceOnChainWithdraw(
        DecoderCustomTypes.OnChainWithdraw memory oldRequest,
        uint16, /*discount*/
        uint24 /*secondsToDeadline*/
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(oldRequest.user, oldRequest.assetOut);
    }
}
