// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Yield Basis LT (leveraged liquidity token, e.g. yb-WBTC, yb-cbBTC). Approving the asset to the LT
///         goes through BaseDecoderAndSanitizer.approve.
abstract contract YieldBasisDecoderAndSanitizer is BaseDecoderAndSanitizer {
    //============================== YIELD BASIS LT ===============================

    /// @dev LT.deposit(assets, debt, min_shares, receiver). The asset is pulled from the caller and the
    ///      crvUSD debt from the LT's own AMM, so only the receiver of the shares is checked.
    function deposit(uint256, /*assets*/ uint256, /*debt*/ uint256, /*min_shares*/ address receiver)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    /// @dev LT.withdraw(shares, min_assets, receiver). It burns the caller's own shares, so only the
    ///      receiver of the asset is checked.
    function withdraw(uint256, /*shares*/ uint256, /*min_assets*/ address receiver)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }
}
