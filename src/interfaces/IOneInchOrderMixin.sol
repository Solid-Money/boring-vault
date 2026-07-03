// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

interface IOneInchOrderMixin {
    function rawRemainingInvalidatorForOrder(address maker, bytes32 orderHash) external view returns (uint256);
    /// @dev 2nd arg is a RAW nonce, not a pre-shifted slot: 1inch's BitInvalidatorLib.checkSlot applies
    ///      `nonce >> 8` internally to pick the invalidator word. Named `nonce` (1inch misleadingly calls it
    ///      `slot`) so callers do not pre-shift. See OneInchAdapter.filledAmount (M-01).
    function bitInvalidatorForOrder(address maker, uint256 nonce) external view returns (uint256);
}
