// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

/// @notice Tick/price math for the Tempo stablecoin DEX, shared by TempoAdapter and
///         TempoLimitOrderManager so escrow/refund/proceeds amounts are computed with a single
///         implementation.
/// @dev MUST replicate the precompile's rounding exactly (tempoxyz/tempo
///      `crates/precompiles/src/stablecoin_dex/orderbook.rs`, commit 194dec5c):
///      quote = base * price / PRICE_SCALE with explicit rounding direction, where
///      price = PRICE_SCALE + tick. Escrow and refunds round UP, payouts round DOWN.
///      The swapper's `refund = inputAmount - filledAmount` arithmetic is only exact if every
///      conversion here matches the precompile's direction for that flow.
library TempoDexMath {
    int16 internal constant MIN_TICK = -2000;
    int16 internal constant MAX_TICK = 2000;
    int16 internal constant TICK_SPACING = 10;
    uint256 internal constant PRICE_SCALE = 100_000;
    /// @notice Minimum maker order size ($100 at 6 decimals). Taker swaps have no minimum.
    uint128 internal constant MIN_ORDER_AMOUNT = 100_000_000;

    error TempoDexMath__TickOutOfBounds();
    error TempoDexMath__TickNotAligned();
    error TempoDexMath__AmountOverflow();

    /// @notice Reverts unless `tick` is in [MIN_TICK, MAX_TICK] and aligned to TICK_SPACING.
    function validateTick(int16 tick) internal pure {
        if (tick < MIN_TICK || tick > MAX_TICK) revert TempoDexMath__TickOutOfBounds();
        if (tick % TICK_SPACING != 0) revert TempoDexMath__TickNotAligned();
    }

    /// @notice Scaled price for a tick: PRICE_SCALE + tick (tick 0 = $1 peg, ±2% band).
    function tickToPrice(int16 tick) internal pure returns (uint256) {
        // safe: tick >= MIN_TICK = -2000 keeps the sum strictly positive
        return uint256(int256(PRICE_SCALE) + int256(tick));
    }

    /// @notice base -> quote, rounding up (precompile direction for escrow and cancel refunds
    ///         of bids, and for quote owed to ask makers per fill).
    function baseToQuoteUp(uint128 baseAmount, int16 tick) internal pure returns (uint128) {
        return _toUint128(FixedPointMathLib.mulDivUp(baseAmount, tickToPrice(tick), PRICE_SCALE));
    }

    /// @notice base -> quote, rounding down (precompile direction for quote paid out to takers;
    ///         used as the conservative output estimate for ask orders).
    function baseToQuoteDown(uint128 baseAmount, int16 tick) internal pure returns (uint128) {
        return _toUint128(FixedPointMathLib.mulDivDown(baseAmount, tickToPrice(tick), PRICE_SCALE));
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert TempoDexMath__AmountOverflow();
        return uint128(value);
    }
}
