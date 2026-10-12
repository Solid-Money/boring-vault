// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {SpendingLimit} from "../libraries/SpendingLimitLib.sol";

/**
 * @notice How a Safe's card spend is funded. Exactly one mode is active at a time, but `Smart`
 *         permits BOTH funding paths, so "one mode" is not the same as "one path".
 *
 * @dev **Order is load-bearing.** `_modeRank` is `uint8(m)`, and the mode-switch delay rule is
 *      "delayed iff the rank RISES". Members are therefore ordered by how much a compromised
 *      spender key can reach, least first, and a new member appended without thought would silently
 *      inherit the highest rank.
 */
enum Mode {
    /// @dev The asset is SOLD. Tokens move Safe -> settlementTreasury.
    Debit,
    /// @dev The asset is LOCKED. Collateral moves Safe -> module escrow and USD debt is booked.
    Credit,
    /**
     * @dev BOTH paths are permitted and the backend chooses per transaction.
     *
     *      Grants **capability, never policy**: every cap, band, limit and replay guard binds
     *      exactly as it does in the two exclusive modes. In particular both paths share one
     *      `SpendingLimit` and one `booked[safe][txId]` marker, so a Smart Safe cannot consume two
     *      daily windows and one `txId` cannot be charged once on each path.
     *
     *      Which path a given transaction takes is decided off-chain. This module deliberately has
     *      no opinion on it: the choice depends on borrow APY, user preference and merchant
     *      context, none of which are on-chain, and bounding what is *possible* is this contract's
     *      job while choosing among possible paths is not a safety property.
     */
    Smart
}

/**
 * @notice Per-token spend permission, collateral eligibility and risk parameters.
 * @dev `spendable` and `collateral` are **independent** because being sellable and being pledgeable
 *      are different properties. soETH is the motivating case: a holder does not want it sold to buy
 *      coffee, so `collateral: true, spendable: false` makes that structural rather than a backend
 *      policy. A `collateral && !spendable` token means its holder can only use Credit mode.
 *
 *      Three distinct levers exist for restricting a token, with deliberately different semantics:
 *
 *        - `tokenPaused` (guardian, immediate) — stops NEW risk. The token cannot be sold, cannot
 *          be newly locked, cannot be handed over as repayment, and stops contributing to borrowing
 *          power. It still counts toward liquidation capacity, so pausing can never manufacture a
 *          liquidation. It lives OUTSIDE this struct, in its own mapping: every function that
 *          rewrites a token's configuration writes the whole struct, so a `paused` field was
 *          silently cleared by any config authored before the incident — including by the
 *          permissionless `commitTokenConfig`.
 *        - `collateral = false` (owner, delayed) — stops new pledging without touching what is
 *          already escrowed.
 *        - `disallowToken` (owner, blocked while any balance is escrowed) — full removal.
 *
 * @param spendable May be sold in Debit mode
 * @param collateral May be newly locked in Credit mode
 * @param tokenDecimals Read from the token at allowlist time, never supplied
 * @param haircutBps Quote-only valuation buffer; never applied to settlement
 * @param liquidationBonusBps Paid to a liquidator out of seized collateral
 * @param ltv WAD. The hard bound asserted after a credit spend
 * @param liquidationThreshold WAD. Must exceed `ltv`; `threshold + bonus` must not exceed 1e18
 * @param maxStalenessSeconds The module's OWN staleness bound, independent of the price provider's
 * @param minPriceUsd Module-side sanity floor, independent of the provider (6 decimals)
 * @param maxPriceUsd Module-side sanity ceiling AT `ceilingAnchor`; a price above the effective
 *        ceiling is CAPPED, not rejected
 * @param ceilingGrowthPerSec How fast the ceiling is allowed to drift upward, in 1e-18 USD-6dp
 *        units per second. Zero is a static ceiling, which is correct for anything that is not
 *        expected to appreciate. See `_price` for why a static ceiling is wrong for a share
 * @param ceilingAnchor Timestamp `maxPriceUsd` is quoted at. Required whenever the ceiling drifts
 */
struct TokenConfig {
    bool spendable;
    bool collateral;
    uint8 tokenDecimals;
    uint16 haircutBps;
    uint16 liquidationBonusBps;
    uint64 ltv;
    uint64 liquidationThreshold;
    uint64 maxStalenessSeconds;
    uint64 minPriceUsd;
    uint64 maxPriceUsd;
    uint64 ceilingGrowthPerSec;
    uint64 ceilingAnchor;
}

/**
 * @notice Per-Safe card state. One limit, one mode, one debt position.
 * @param registered Safe has opted into card spending on this module
 * @param mode Stored mode; read through `getMode` so a matured `incomingMode` is honoured
 * @param incomingMode Pending mode, only ever a HIGHER-ranked mode than `mode` — see `_modeRank`.
 *        A switch that lowers the rank is de-risking and applies immediately, so it never parks here
 * @param incomingModeStartTime When `incomingMode` becomes effective. 0 when none pending
 * @param unhealthySince First observation that health fell below 1. Gates the liquidation grace period
 * @param normalizedDebt Debt in index-normalised units; `debtUsd = normalizedDebt * index / WAD`
 * @param forcedDebtUsd Outstanding `is_mandatory` liability booked without our approval. Ops signal;
 *        maintained in both directions, so a reversed or written-off forced spend leaves it
 * @dev The `SpendingLimit` deliberately does NOT live here. `deregisterSafe` deletes this struct,
 *      and a limit reachable by that `delete` would let any Safe reset its own rolling windows —
 *      and re-register straight at the org ceiling — by deregistering and registering again. It
 *      lives in `SolidCashStorageV2._safeLimit`, which deregistration cannot reach.
 */
struct SafeConfig {
    bool registered;
    Mode mode;
    Mode incomingMode;
    uint64 incomingModeStartTime;
    uint64 unhealthySince;
    uint256 normalizedDebt;
    uint256 forcedDebtUsd;
}

/**
 * @notice A card operation booked against a Safe, keyed by the backend's settlement identifier.
 * @dev **`exists` is the replay marker, not `bookedUsd`.** Keying replay on a non-zero amount made
 *      the marker erasable: `adjustBookedSpend` writes `bookedUsd` directly and its lower bound is
 *      `reversedUsd`, which is zero for a never-reversed record — so a settle-rejection arriving as
 *      amount 0 silently freed the `txId` to be charged again. A dedicated bit cannot be reached
 *      that way, and replay protection is correctness rather than policy.
 *
 *      `originalUsd` is the amount first authorized and is never rewritten. `maxAdjustmentBps` is
 *      measured against it, so repeated adjustments cannot ratchet: bounding each call against the
 *      previous call's result compounds geometrically and bounds nothing overall.
 *
 *      `isForced` lets a reversal or a write-off decrement `SafeConfig.forcedDebtUsd` by exactly the
 *      part that was forced, so the ops signal stays true in both directions.
 *
 *      `uint72` holds 4.7e21, i.e. ~$4.7e15 at 6 decimals, so all three amounts plus all three flags
 *      are one slot.
 */
struct BookedSpend {
    uint72 originalUsd;
    uint72 bookedUsd;
    uint72 reversedUsd;
    bool isCredit;
    bool isForced;
    bool exists;
}

/// @notice A Safe's single armed collateral withdrawal.
struct PendingWithdrawal {
    address token;
    uint64 readyAt;
    uint256 amount;
}

/// @notice A risk-increasing token configuration change waiting out `paramChangeDelay`.
struct PendingTokenConfig {
    uint64 activationTime;
    TokenConfig cfg;
}

/// @notice Org-wide caps, delays and sizing parameters.
struct Params {
    uint256 maxPerTxUsd;
    uint256 maxDailyLimitUsd;
    uint256 maxMonthlyLimitUsd;
    uint256 defaultDailyLimitUsd;
    uint256 defaultMonthlyLimitUsd;
    uint256 maxDebtPerSafeUsd;
    uint256 maxGlobalDebtUsd;
    /**
     * @dev Per-call ceiling on `bookForcedSpend`. A mandatory card authorization is a real card
     *      transaction and is bounded like one; without this the only bound on the amount a
     *      compromised `CREDIT_SPENDER_ROLE` key can book in one call is the `uint72` field width.
     *      Separate from `maxPerTxUsd` because a forced spend has already happened off-chain and
     *      refusing to record it is worse than recording it, so the two want different numbers.
     */
    uint256 maxForcedSpendUsd;
    uint256 dustFloorUsd;
    uint256 minPositionUsd;
    uint16 targetLtvBps;
    uint16 closeFactorBps;
    uint16 maxAdjustmentBps;
    uint64 modeDelay;
    uint64 limitRaiseDelay;
    uint64 collateralWithdrawDelay;
    uint64 liquidationGracePeriod;
    uint64 graceFloorHf;
    uint64 paramChangeDelay;
    /**
     * @dev Delay on a PER-SAFE limit waiver. Deliberately separate from `paramChangeDelay`, which is
     *      floored by `liquidationGracePeriod` — sharing it would mean a fast operational waiver could
     *      only be bought by shortening the window that protects users from a bad oracle print.
     *      Two blast radii, two delays: one account here, the whole book on `paramChangeDelay`.
     */
    uint64 limitWaiveDelay;
}

/// @notice The computed shape of one liquidation, kept in memory so `liquidate` stays inside the
///         EVM's addressable stack depth.
struct LiquidationSizing {
    uint256 repaidUsd;
    uint256 seized;
    uint256 repayTokenAmount;
}
