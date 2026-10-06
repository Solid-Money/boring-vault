// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";
import {PriceFeedConfigV2, PriceFeedKindV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";

/**
 * @title SpendModuleV2Config
 * @notice Deployment parameters and the on-disk record for the Phase 3 credit-line module.
 * @dev Inherited by every script in this directory so there is one place a parameter is written and
 *      one place addresses are read from — the same shape as `SpendModuleConfig` for v1.
 *
 *      **Two records, deliberately.** v2 writes
 *      `deployments/addresses/<Network>/SpendModuleV2.json` and reads v1's addresses out of
 *      `SpendModule.json`. They are not merged, because v1's `saveAddress` re-serialises its file
 *      from a fixed key list: a v2 key written into it would be silently dropped the next time any
 *      v1 script ran.
 *
 *      **v1 stays live.** Migration is per-user and has no deadline, so at any moment some Safes are
 *      on v1 and some on v2. Nothing here revokes a v1 grant, and the authority is v1's, reused.
 */
abstract contract SpendModuleV2Config is Script {
    // ========================================= EXTERNAL ADDRESSES (FUSE) =========================================

    /// @dev soUSD on Fuse — the LayerZero OFT share token users hold. Spendable and collateral.
    address internal constant SOUSD = 0x75333830E7014e909535389a6E5b0C02aA62ca27;

    /// @dev Accountant pricing soUSD, reached via the Fuse soUSD teller's `accountant()`. base = USDC.
    address internal constant SOUSD_ACCOUNTANT = 0x47A5e832E1178726dd13AdD762774A704878AD98;

    /// @dev USDC on Fuse (Stargate-bridged) — spendable, collateral, and soUSD's accountant base.
    address internal constant USDC = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;

    /// @dev USDT on Fuse (Stargate-bridged) — spendable and collateral.
    address internal constant USDT = 0x3695Dd1D1D43B794C0B13eb8be8419Eb3ac22bf7;

    uint256 internal constant FUSE_CHAIN_ID = 122;

    uint256 internal constant WAD = 1e18;
    uint16 internal constant MAX_BPS = 10_000;

    // ========================================= ROLE IDS =========================================

    /// @dev v1's spender role. The SAME key holds it on both modules — one backend, two cohorts.
    uint8 internal constant SPENDER_ROLE = 1;

    /// @dev v1's guardian role, extended on v2 to the two new breakers.
    uint8 internal constant GUARDIAN_ROLE = 2;

    /**
     * @dev New, and deliberately a different key from `SPENDER_ROLE`.
     *
     *      It reaches every path that can create or unwind debt and can move a user's assets into
     *      escrow. A debit spender that also held this could turn a Safe's balance into collateral
     *      and book debt against it; splitting them means a compromise of the high-volume sweep key
     *      cannot do that.
     */
    uint8 internal constant CREDIT_SPENDER_ROLE = 3;

    /**
     * @dev Granted on the CORE, over `liquidate`, to exactly one address: the `SolidLiquidator`
     *      contract. Never to an EOA.
     *
     *      Liquidation used to be permissionless, which composed with `bookForcedSpend` into a
     *      complete theft: a compromised `CREDIT_SPENDER_ROLE` key books unbacked debt against any
     *      registered Safe, then liquidates the position it just created and keeps the collateral
     *      plus the 5% bonus. Gating the extraction end is what closes it, because the card flow
     *      cannot accept a cap on a mandatory charge that has already happened.
     */
    uint8 internal constant LIQUIDATOR_ROLE = 4;

    /**
     * @dev Granted on the `SolidLiquidator` contract, over its own `liquidate`.
     *
     *      **Must be a different key from both spender roles.** The whole value of routing
     *      liquidation through a contract is that manufacturing a liquidation then requires two
     *      independent compromises; handing this to the credit spender would collapse it back to
     *      one. Even then the proceeds only reach the treasury, so this key cannot steal — it can at
     *      most liquidate positions the module already considers eligible.
     */
    uint8 internal constant LIQUIDATION_OPERATOR_ROLE = 5;

    // ========================================= ORG CAPS =========================================

    /**
     * @dev The multiple the app derives a monthly cap from a chosen daily one
     *      (`MONTHLY_LIMIT_MULTIPLIER` in solid-ui's `constants/cardSpendModule.ts`).
     *
     *      It has to be reflected here, because the app filters a daily preset out unless
     *      `daily * this <= maxMonthlyLimitUsd`. A monthly ceiling below the multiple of the daily
     *      one does not merely cap the month — it makes the top daily options *disappear from the
     *      picker*, with no error anywhere to explain why.
     */
    uint256 internal constant MONTHLY_LIMIT_MULTIPLIER = 10;

    /// @dev Live ceilings clamping every Safe on every read — the rollout throttle. Matches v1.
    uint256 internal constant MAX_DAILY_LIMIT_USD = 25_000e6;
    uint256 internal constant MAX_MONTHLY_LIMIT_USD = MAX_DAILY_LIMIT_USD * MONTHLY_LIMIT_MULTIPLIER;

    /**
     * @dev Set equal to the daily ceiling so it can never be the binding constraint.
     *      `_maxCanSpendUsd` clamps every Safe's daily headroom to `MAX_DAILY_LIMIT_USD`, so any
     *      spend the rolling windows allow is already at or under this — which leaves the daily
     *      limit as the only cap a cardholder has to reason about.
     *
     *      Never 0: the module's check is `totalUsd > maxPerTxUsd`, so 0 rejects every spend, while
     *      the backend's authorize path reads 0 as "no per-transaction cap" and would approve what
     *      the module then refuses.
     */
    uint256 internal constant MAX_PER_TX_USD = MAX_DAILY_LIMIT_USD;

    /// @dev Applied when a Safe registers passing 0. Must not exceed the ceilings, or every
    ///      `registerSafe` reverts. Equal to them, matching the app's activation default.
    uint256 internal constant DEFAULT_DAILY_LIMIT_USD = MAX_DAILY_LIMIT_USD;
    uint256 internal constant DEFAULT_MONTHLY_LIMIT_USD = MAX_MONTHLY_LIMIT_USD;

    /// @dev Quote-only reserve, so a quote cannot round up past what `spend` collects.
    uint256 internal constant DUST_FLOOR_USD = 0;

    // ========================================= CREDIT CAPS =========================================

    /**
     * @dev COMMERCIAL DECISION. The most debt one Safe may carry, on top of the collateral
     *      requirement it can never escape. Start here and raise it with one `setParams`.
     */
    uint256 internal constant MAX_DEBT_PER_SAFE_USD = 25_000e6;

    /**
     * @dev COMMERCIAL DECISION, and the single most important number in this file.
     *
     *      Solid's float solvency, not a user allowance: it is the total credit the whole book may
     *      draw against money Solid has already paid the card network. It is never waivable and
     *      every debt-creating path checks it, so it is the real rollout throttle — raise it as the
     *      float and the operational confidence grow, rather than opening at the target.
     */
    uint256 internal constant MAX_GLOBAL_DEBT_USD = 250_000e6;

    /**
     * @dev Ceiling on one `bookForcedSpend` call, derived rather than written.
     *
     *      A mandatory (`is_mandatory`) authorization is a real card transaction, so it is bounded
     *      like one. It is a separate number from `maxPerTxUsd` because a forced spend has already
     *      happened off-chain and refusing to record it is worse than recording it — but "cannot
     *      refuse" is not "must be unbounded", and without this the only bound is the `uint72`
     *      field width.
     */
    uint256 internal constant MAX_FORCED_SPEND_USD = MAX_PER_TX_USD;

    /**
     * @dev At or below this, a position is fully clearable in one liquidation rather than being
     *      close-factor limited. It stops a dust position becoming permanently unprofitable to
     *      liquidate and stranding as bad debt.
     */
    uint256 internal constant MIN_POSITION_USD = 25e6;

    // ========================================= SIZING AND LIQUIDATION =========================================

    /**
     * @dev The buffer `spendCredit` sizes collateral at, as a fraction of each token's own LTV.
     *
     *      **Read it as a health factor, because that is what it sets.** A position opens at
     *      `liquidationThreshold / (ltv * TARGET_LTV_BPS)`, so on 90/95 soUSD this 9,500 puts every
     *      new position at HF 1.111 — within a rounding error of the 1.1 floor ether.fi's
     *      `LendGateway` enforces in production, and the reason this is not a rounder number.
     *
     *      It was 8,000, which reads as a modest buffer and is not: `SolidSpendLens` quotes
     *      prospective collateral at this same ratio, so it set the credit limit a cardholder is
     *      SHOWN. At 8,000 a Safe holding $26.75 of soUSD was offered $19.26 — an effective 72% on
     *      an asset configured at 90% — while `spendCredit` would have authorized $24.07. The
     *      quote and the bound are not meant to be 25% apart.
     *
     *      Capped at 9,500 by `SolidCashConfigLib.MAX_TARGET_LTV_BPS`: at the bound itself, one
     *      unit of rounding decides whether a credit spend succeeds.
     *
     *      This is the parameter reachable from `setParams`, so it is where the quote is corrected
     *      without a redeploy. What it CANNOT do is make the quote and the bound the same number:
     *      `_requireWithinBounds`' successor still checks raw `ltv`, and
     *      `processCollateralWithdrawal` lets an escrowed position be drawn back down to HF 1.056.
     *      Closing both needs the floor to become a parameter of its own, which is a module
     *      redeploy — cheap today (no debt, no registered Safes, setters unsealed), and not cheap
     *      after a second collateral is listed, since one LTV multiplier cannot express one health
     *      factor across two tokens with different threshold/LTV ratios.
     */
    uint16 internal constant TARGET_LTV_BPS = 9_500;

    /// @dev Most of a position one liquidation may retire. Standard half-close.
    uint16 internal constant CLOSE_FACTOR_BPS = 5_000;

    /**
     * @dev How far a settlement may exceed the amount originally authorized — tips, FX, a partial
     *      capture that lands higher. Measured against `BookedSpend.originalUsd`, so repeated
     *      adjustments cannot ratchet. 25% covers a US restaurant tip adjustment.
     */
    uint16 internal constant MAX_ADJUSTMENT_BPS = 2_500;

    /**
     * @dev Health factor below which liquidation is immediate, skipping the grace period.
     *
     *      Grace exists because Solid holds the soUSD accountant's rate-update role, so a single
     *      wrong print must not cascade liquidations — and a wrong print lands in a shallow band
     *      just under 1.0. A real crash blows through this, where waiting only accrues bad debt.
     */
    uint64 internal constant GRACE_FLOOR_HF = 0.95e18;

    // ========================================= DELAYS =========================================

    /**
     * @dev Switching into Credit mode is IMMEDIATE.
     *
     *      Not because the delay is worthless — it is the window in which a switch the user did not
     *      intend can be cancelled — but because there is no countdown anywhere in the app. A
     *      non-zero value works correctly: the user signs, nothing observable changes, the card
     *      keeps behaving as Debit, and no screen explains why or says when it will stop. An
     *      unexplained delay is a worse failure than no delay.
     *
     *      What is given up: a user socially engineered into signing `setMode(Credit)` gets it at
     *      once. They can still switch back immediately — `setMode(Debit)` is instant in every
     *      configuration — and every other credit control still binds: collateral, the per-Safe debt
     *      cap, the global debt cap, both pauses.
     *
     *      Raise it the moment the app grows a countdown. `setMode`'s cancellation path already
     *      exists and starts working the instant this is non-zero.
     */
    uint64 internal constant MODE_DELAY = 0;

    /**
     * @dev Raising a spending limit is IMMEDIATE, matching v1's live value.
     *
     *      Same reasoning, and the same precedent: v1 runs at 0 today, and the card spending UI
     *      shows no wait on a limit increase because of it. Setting v2 higher than v1 would make the
     *      same user action behave differently on either side of a migration the user did not ask
     *      for and cannot see.
     *
     *      The cost is real and worth naming: a raise is the risk-increasing direction, and at 0
     *      there is no window in which one nobody intended can be cancelled.
     *      `cancelPendingSpendingLimitIncrease` still exists and starts working the instant this is
     *      non-zero. Lowering a limit is immediate in every configuration.
     *
     *      **0 means "next block", not "same block".** `getCurrentLimit` matures a pending increase
     *      on `block.timestamp > activationTime`, strictly — while `_currentMode` matures a mode
     *      switch on `>=`. So a raise lands a second later and a mode switch lands at once, and a
     *      caller that raised a limit and spent against the new one in the SAME transaction would
     *      still be on the old cap. Nothing in the app does that; a backend script might. This
     *      matches v1's behaviour exactly, which also runs at 0.
     */
    uint64 internal constant LIMIT_RAISE_DELAY = 0;

    /**
     * @dev Only has to stop a withdrawal of already-escrowed collateral racing an in-flight
     *      `spendCredit` that counted it — a window of seconds, not an authorize-to-settle window.
     *      Floored at 1 minute by `SolidCashConfigLib.MIN_COLLATERAL_WITHDRAW_DELAY`.
     */
    uint64 internal constant COLLATERAL_WITHDRAW_DELAY = 5 minutes;

    /**
     * @dev **One day**, because this window's job changed.
     *
     *      It was originally sized to outlast one soUSD accountant update cycle: the live accountant
     *      enforces a ~1,000s minimum update delay, so grace shorter than that could expire before a
     *      wrong rate could possibly be corrected. Thirty minutes cleared that bar.
     *
     *      It now also has to be long enough for a *person* to act. Liquidation is the response to a
     *      position that has gone bad, and the two things that can rescue one — the user repaying,
     *      and ops reversing a booking that should not have existed — both happen on human time, not
     *      on oracle time. A day is the window in which a cardholder who is notified of a shortfall
     *      can actually do something about it before Solid seizes collateral at a 5% bonus.
     *
     *      It is also the backstop behind `bookForcedSpend`: a forced booking never takes the
     *      `graceFloorHf` shortcut (see `_requireLiquidatable`), so this is the minimum time between
     *      a compromised credit-spender key creating unbacked debt and anyone being able to act on
     *      it. `reverseSpend` unwinds it well inside that.
     *
     *      Cheap at launch, because only soUSD is collateral and soUSD's price comes from the
     *      accountant rather than a market — there is no market move for a long grace to be wrong
     *      about. Revisit this the day a volatile asset becomes collateral: waiting a day through a
     *      real crash is bad debt Solid absorbs, which is exactly what `GRACE_FLOOR_HF` is for.
     *
     *      Floored at 10 minutes by `SolidCashConfigLib.MIN_LIQUIDATION_GRACE`.
     */
    uint64 internal constant LIQUIDATION_GRACE_PERIOD = 1 days;

    /**
     * @dev The objection window on every risk-increasing configuration change, and on the org-wide
     *      limit waiver. Must be at least `LIQUIDATION_GRACE_PERIOD`, which is what raises it to a
     *      day alongside the grace period above — `validateParams` enforces the relationship, and
     *      `requestParamChangeDelayReduction` cannot later take it back below grace either.
     *
     *      That coupling is deliberate rather than incidental: a configuration change that lands
     *      faster than the grace period could alter the terms of a liquidation that is already
     *      counting down.
     *
     *      `setParams` can raise this freely but can never lower it; lowering goes through
     *      `requestParamChangeDelayReduction` and waits out the window it is about to remove.
     */
    uint64 internal constant PARAM_CHANGE_DELAY = 1 days;

    /**
     * @dev Delay on a PER-SAFE limit waiver. One hour, not zero.
     *
     *      Unlike `MODE_DELAY` and `LIMIT_RAISE_DELAY`, no user is waiting on this — it is an admin
     *      action with no UI at all — so a delay costs no cardholder anything and buys an hour in
     *      which anyone watching the event can object. That matters because a waived Safe's per-tx
     *      and rolling caps are gone, which for a Debit Safe means the spender key can take the whole
     *      balance in one swipe.
     *
     *      0 is supported and documented for incident response. Set it deliberately, not by default.
     */
    uint64 internal constant LIMIT_WAIVE_DELAY = 1 hours;

    /**
     * @dev COMMERCIAL DECISION. Borrow rate per second in WAD, fixed rather than utilization-driven.
     *
     *      **4% effective per year**, the same rate whatever the collateral: debt is one USD figure
     *      per Safe carried on one global index, so there is no per-token rate to set. Collateral
     *      risk is priced through `ltv` and `liquidationThreshold` instead.
     *
     *      **The unit is a CONTINUOUSLY COMPOUNDED rate, so it is `ln(1 + target)`, not the target.**
     *      `_accrue` advances the index as `index * (1 + apy * dt)` — linear inside one step, but
     *      compounding across steps, and the index is global so *any* Safe's activity advances it
     *      for the whole book. Accrual is therefore frequent enough to treat as continuous. Writing
     *      `0.04e18 / 365 days` instead would charge 4.081% effective, not 4%.
     *
     *          ln(1.04) * 1e18 / 365 days = 1_243_680_656
     *          ln(1.05) * 1e18 / 365 days = 1_547_125_957   (5%, for reference)
     *
     *      Bounded by `MAX_BORROW_APY_PER_SECOND` (21_979_552_909 = 100% effective per year), so
     *      this sits at 5.7% of the maximum the module will accept.
     *
     *      `setBorrowApyPerSecond` is a live owner lever and calls `_accrue()` before it writes, so
     *      changing the rate later cannot retroactively reprice elapsed time.
     */
    uint64 internal constant BORROW_APY_PER_SECOND = 1_243_680_656;

    // ========================================= TOKEN RISK =========================================

    /**
     * @dev Module-side band for the stablecoins. 2%, and deliberately not the provider's number.
     *
     *      The module's band is the independent backstop against an upgradeable provider, and it is
     *      only a second layer if it is independently chosen. v1 set both to 3% — identical, which
     *      is one layer wearing two hats, and a standing finding against it. Here the two have
     *      different jobs: the provider does absolute sanity (5% either way, wide enough that it
     *      only ever catches something absurd), and the module does the tight policy bound.
     *
     *      2% means a genuine depeg makes the asset unusable rather than letting the module keep
     *      collecting $1.00 of value per $0.90 of token. Note what that costs when it fires: the
     *      asset stops contributing to spending power and every spend touching it reverts, so a
     *      depeg is an incident and not a graceful degradation. That is the right trade for a card —
     *      over-collecting a user's tokens is worse — and it is why the backend's draw order puts
     *      soUSD behind both stables.
     *
     *      Tighter than v1's 3%, so a depeg between 2% and 3% would leave a v1 Safe spending and a
     *      v2 Safe declining. That divergence is intended: it is the newer cohort being held to the
     *      tighter bound, not an accident of configuration.
     */
    uint64 internal constant STABLE_MIN_PRICE_USD = 0.98e6;
    uint64 internal constant STABLE_MAX_PRICE_USD = 1.02e6;

    /**
     * @dev Module-side floor for soUSD. The ceiling is NOT a constant — see `soUsdCeiling`.
     *
     *      soUSD is a monotonically appreciating USD share, so a floor well under $1 is slack rather
     *      than a real bound; the ceiling is the side that matters and the side that used to expire.
     */
    uint64 internal constant SOUSD_MIN_PRICE_USD = 0.95e6;

    /**
     * @dev Headroom above the live price at deploy, and the rate the ceiling is then allowed to
     *      drift upward at.
     *
     *      A static ceiling on an appreciating asset is an outage with a computable date: above it,
     *      debit settlement, collateral locking, all three repay paths and liquidation refuse at
     *      once. So the ceiling is anchored at deploy and rises — what it bounds is the *rate of
     *      change*, which is what a bad print has to beat, rather than a level honest yield beats on
     *      its own.
     *
     *      30% headroom absorbs a burst; 25%/yr of drift comfortably exceeds any plausible soUSD
     *      yield while still rejecting a print that jumps. Capped at 100%/yr of the anchored ceiling
     *      by `SolidCashConfigLib.validateTokenConfig`.
     */
    uint16 internal constant SOUSD_CEILING_HEADROOM_BPS = 3_000;
    uint16 internal constant SOUSD_CEILING_GROWTH_APY_BPS = 2_500;

    /// @dev Quote-only valuation buffer. Never applied to settlement, so 0 is right for a stablecoin
    ///      and for a stable-denominated share alike; a volatile asset would need a real buffer.
    ///      Applies to a spendable token's quoted value too, so it is kept for the stables even
    ///      though they no longer back credit.
    uint16 internal constant STABLE_HAIRCUT_BPS = 0;
    uint16 internal constant SOUSD_HAIRCUT_BPS = 0;

    /**
     * @dev The module's OWN staleness bound, enforced on top of the provider's.
     *
     *      Independent because the provider is upgradeable: a band catches an absurd price but not a
     *      stale-but-plausible one, which is precisely the exploitable case.
     */
    uint64 internal constant SOUSD_MAX_STALENESS = 7 days;
    uint64 internal constant STABLE_MAX_STALENESS = 1 days;

    /// @dev LTV / liquidation threshold / bonus, in WAD and bps.
    ///      `threshold` must exceed `ltv`, and `threshold + bonus` must not exceed 1e18 — otherwise a
    ///      liquidation could seize more value than the position holds.
    ///
    ///      There is deliberately no `STABLE_*` set here: third-party stablecoins are spendable but
    ///      never collateral (see `_stableConfig`), so they have no LTV to state. Adding one is a
    ///      decision that comes with an oracle, not a constant.
    uint64 internal constant SOUSD_LTV = 0.90e18;
    uint64 internal constant SOUSD_LIQ_THRESHOLD = 0.95e18;
    uint16 internal constant SOUSD_LIQ_BONUS_BPS = 500;

    struct SpendTokenParams {
        address token;
        TokenConfig config;
        string label;
    }

    /**
     * @notice Every asset the module allowlists at deploy.
     * @dev Order becomes `_allowedTokens` push order, which the lens returns its per-token breakdown
     *      in — and which the backend deliberately does NOT treat as the draw order
     *      (`DEFAULT_SPEND_TOKEN_PRIORITY` in solid-backend). Listed cheapest-first anyway so the two
     *      agree by default: a card spend drains idle stables before it touches the yield-bearing
     *      share.
     *
     *      **Only soUSD is collateral.** The stables are spendable and nothing else, so the whole
     *      credit book is backed by Solid's own share token — the one asset whose value this system
     *      already has to trust an accountant for. Nothing here depends on a market price, which is
     *      what makes launching on a chain with no usable oracle a sound position rather than an
     *      accepted risk. See `_stableConfig`.
     * @param sousdCeiling Computed from the live price at deploy; see `soUsdCeiling`.
     * @param anchor Timestamp the soUSD ceiling is quoted at. `block.timestamp` at deploy.
     */
    function spendTokens(uint64 sousdCeiling, uint64 anchor)
        internal
        pure
        returns (SpendTokenParams[] memory tokens)
    {
        tokens = new SpendTokenParams[](3);
        tokens[0] = SpendTokenParams(USDC, _stableConfig(), "USDC");
        tokens[1] = SpendTokenParams(USDT, _stableConfig(), "USDT");
        tokens[2] = SpendTokenParams(SOUSD, _sousdConfig(sousdCeiling, anchor), "soUSD");
    }

    /**
     * @notice Assets the module accepts as INCOMING payment against debt (`setRepayTender`).
     * @dev Strictly narrower than `spendable`, and the reason is the bare peg.
     *
     *      Valuing a token at an uncorroborated $1.00 is defensible for a *settlement*: the amount
     *      is bounded by `maxPerTxUsd`, the user chose to spend it, and being slightly wrong costs
     *      one transaction. It is not defensible for *tender*, because `_sizeRepay` uses that same
     *      price to decide how much debt a payment retires — so a token accepted at par while it
     *      trades at 90 cents lets a borrower settle a dollar of debt for ninety, and lets a
     *      liquidator buy a dollar of someone's soUSD for ninety. That is a direct transfer from
     *      Solid and from the borrower to whoever is holding the depegged asset.
     *
     *        - **soUSD** — priced through the accountant, which is the one price this system already
     *          trusts for every other purpose. Also the only collateral, so it is what
     *          `repayFromCollateral` unwinds into.
     *        - **USDC.e** — soUSD's accountant base. The vault's NAV is already denominated in it,
     *          so quoting it at $1.00 as tender asserts nothing the accountant does not assert
     *          already. Accepting it is therefore free of new assumptions.
     *        - **USDT is deliberately absent.** Spendable, never tender. Nothing on Fuse observes
     *          its price, and unlike USDC.e it is not load-bearing anywhere else in the system, so
     *          there is no existing assumption to lean on.
     *
     *      The day a real feed exists for a stablecoin, promote it here and in the provider together
     *      — a `STABLE_ADAPTER` entry makes the peg a ceiling rather than an assertion, which is
     *      exactly the property tender needs.
     */
    function repayTenderTokens() internal pure returns (address[] memory tokens, string[] memory labels) {
        tokens = new address[](2);
        labels = new string[](2);
        tokens[0] = SOUSD;
        labels[0] = "soUSD";
        tokens[1] = USDC;
        labels[1] = "USDC";
    }

    /**
     * @notice A third-party stablecoin: **spendable, never collateral.**
     * @dev The line is deliberate and it is drawn by who issues the asset. Only Solid's own
     *      yield-bearing shares back credit, because their value comes from an accountant this
     *      system already has to trust for other reasons. A third-party token's value comes from a
     *      market, and pricing one honestly needs an oracle — of which **Fuse has none**: Supra is
     *      deprecated, there is no Pyth or Chainlink here, and the whole Algebra DEX holds roughly
     *      $78k of stablecoin depth against a quoted ratio rather than a dollar.
     *
     *      `collateral: false` is what makes the bare USDC.e / USDT pegs sound rather than merely
     *      tolerated. A peg that cannot be corroborated is only ever used to value a single
     *      settlement, bounded by `maxPerTxUsd` — never to size credit against a
     *      `maxGlobalDebtUsd` book. `_borrowingPower` returns 0 for a non-collateral token and
     *      `_positionValue` skips it, so this is enforced by the module rather than by convention.
     *
     *      LTV, liquidation threshold and bonus are therefore **0**, not merely unused:
     *      `validateTokenConfig` only checks them when `collateral` is true, so leaving plausible
     *      numbers here would be inert documentation that the next person could flip live by
     *      changing one boolean. At zero, promoting a stablecoin to collateral *must* set them
     *      explicitly or `validateTokenConfig` reverts on `ltv == 0` — and the flip is classified
     *      risk-increasing either way, so it waits out `paramChangeDelay`.
     */
    function _stableConfig() private pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: false,
            tokenDecimals: 6,
            haircutBps: STABLE_HAIRCUT_BPS,
            // Collateral-only, and zero by design. See the note above.
            liquidationBonusBps: 0,
            ltv: 0,
            liquidationThreshold: 0,
            maxStalenessSeconds: STABLE_MAX_STALENESS,
            minPriceUsd: STABLE_MIN_PRICE_USD,
            maxPriceUsd: STABLE_MAX_PRICE_USD,
            // A peg does not appreciate. A static ceiling is correct here and a drifting one would
            // only widen the window a depegged-upward print could be accepted in.
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    function _sousdConfig(uint64 ceiling, uint64 anchor) private pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: true,
            tokenDecimals: 6,
            haircutBps: SOUSD_HAIRCUT_BPS,
            liquidationBonusBps: SOUSD_LIQ_BONUS_BPS,
            ltv: SOUSD_LTV,
            liquidationThreshold: SOUSD_LIQ_THRESHOLD,
            maxStalenessSeconds: SOUSD_MAX_STALENESS,
            minPriceUsd: SOUSD_MIN_PRICE_USD,
            maxPriceUsd: ceiling,
            ceilingGrowthPerSec: _ceilingGrowth(ceiling),
            ceilingAnchor: anchor
        });
    }

    /// @notice The soUSD ceiling: the live price plus fixed headroom, anchored at deploy.
    function soUsdCeiling(uint256 livePriceUsd) internal pure returns (uint64) {
        require(livePriceUsd != 0, "soUSD price unavailable - cannot anchor the ceiling");
        uint256 ceiling = livePriceUsd + (livePriceUsd * SOUSD_CEILING_HEADROOM_BPS) / MAX_BPS;
        require(ceiling <= type(uint64).max, "soUSD ceiling overflows uint64");
        require(ceiling > SOUSD_MIN_PRICE_USD, "soUSD ceiling below its own floor");
        return uint64(ceiling);
    }

    /// @dev `SOUSD_CEILING_GROWTH_APY_BPS` of the anchored ceiling per year, per second, in WAD.
    function _ceilingGrowth(uint64 ceiling) private pure returns (uint64) {
        uint256 perSecond = (uint256(ceiling) * SOUSD_CEILING_GROWTH_APY_BPS * WAD) / (uint256(MAX_BPS) * 365 days);
        require(perSecond <= type(uint64).max, "ceiling growth overflows uint64");
        return uint64(perSecond);
    }

    // ========================================= PRICE FEEDS (PROVIDER V2) =========================================

    /**
     * @notice The tokens carrying a `STABLE` feed on the live provider.
     * @dev Both are **bare pegs** (`source == 0`), written by the v1 implementation, and they stay
     *      that way at launch. There is no longer a step that corroborates them: Supra is deprecated
     *      on Fuse, and nothing else on this chain can price a dollar — the whole Algebra DEX holds
     *      roughly $78k of stablecoin depth, and a DEX quotes a ratio rather than a dollar in any
     *      case.
     *
     *      That is an accepted, bounded position rather than an oversight, because **neither token
     *      is a module token at launch**: USDC.e is configured here only because it is soUSD's
     *      accountant base, i.e. the unit the vault's NAV is already denominated in. Treating it as
     *      exactly $1.00 asserts nothing the accountant does not already assert.
     *
     *      When a stablecoin becomes collateral it gets a `STABLE_ADAPTER` feed and a real oracle
     *      behind it — `setTokenConfig` refuses to create another bare peg, so that is enforced
     *      rather than remembered.
     */
    function stableTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = USDT;
    }

    // ========================================= KEYS AND EXTERNAL WIRING =========================================

    /// @notice Owns the module and the authority, and holds UPGRADER_ROLE on the provider.
    function owner() internal view returns (address) {
        return vm.envOr("OWNER", 0x3B694d634981Ace4B64a27c48bffe19f1447779B);
    }

    /// @notice Backend sweep key. Holds `SPENDER_ROLE` on BOTH modules — one backend, two cohorts.
    function spender() internal view returns (address) {
        return _requireEnvAddress("SPENDER");
    }

    /**
     * @notice The credit-path key. **May be the same address as `spender`**, and defaults to it.
     * @dev The ROLE split is what is permanent — this module is not upgradeable, so `spend` and
     *      `spendCredit` can never be re-separated once gated on one role. The KEY assignment is a
     *      grant on the shared `FuseRolesAuthority`, reversible by the owner multisig at any time.
     *      Deploy the split; collapse the keys until there is a second signer worth the name.
     */
    function creditSpender() internal view returns (address) {
        return vm.envOr("CREDIT_SPENDER", spender());
    }

    /// @notice Pause key, on both modules.
    function guardian() internal view returns (address) {
        return _requireEnvAddress("GUARDIAN");
    }

    /**
     * @notice The key that drives `SolidLiquidator`. **Required, and must be its own address.**
     * @dev Unlike `CREDIT_SPENDER`, this has no default, because defaulting it to a spender key
     *      would quietly undo the property it exists to create. Liquidation is reachable only
     *      through `SolidLiquidator`, and that contract sends everything it receives to the
     *      treasury — so the value of this key is not that it is trusted, it is that manufacturing a
     *      liquidation requires compromising it *in addition to* `CREDIT_SPENDER`. One key holding
     *      both collapses two independent compromises back into one.
     *
     *      The guardian is an acceptable holder: it is already its own key, and pausing liquidation
     *      and performing one are both incident-response actions.
     */
    function liquidationOperator() internal view returns (address) {
        return _requireEnvAddress("LIQUIDATION_OPERATOR");
    }

    /**
     * @notice The only address `spend` and the repay paths can ever send to.
     * @dev Immutable in BOTH halves, and `setSettersImpl` refuses an implementation whose copy
     *      disagrees. Defaults to v1's recorded treasury, because a v2 Safe settling somewhere else
     *      would split reconciliation across two destinations for no reason.
     */
    function settlementTreasury() internal view returns (address) {
        address recorded = v1Address("SettlementTreasury");
        address value = vm.envOr("SETTLEMENT_TREASURY", recorded);
        require(value != address(0), "SETTLEMENT_TREASURY env var is required (no v1 record found)");
        return value;
    }

    function _requireEnvAddress(string memory key) private view returns (address) {
        address value = vm.envOr(key, address(0));
        require(value != address(0), string.concat(key, " env var is required (see script/spend-module/v2/README.md)"));
        return value;
    }

    function _requireEnvUint(string memory key) private view returns (uint256) {
        require(vm.envExists(key), string.concat(key, " env var is required (see script/spend-module/v2/README.md)"));
        return vm.envUint(key);
    }

    // ========================================= DEPLOYMENT RECORD =========================================

    function _networkDir() private view returns (string memory) {
        if (block.chainid == FUSE_CHAIN_ID) return "Fuse";
        if (block.chainid == 1) return "Mainnet";
        if (block.chainid == 8453) return "Base";
        return vm.toString(block.chainid);
    }

    function deploymentPath() internal view returns (string memory) {
        return string.concat("deployments/addresses/", _networkDir(), "/SpendModuleV2.json");
    }

    function v1DeploymentPath() internal view returns (string memory) {
        return string.concat("deployments/addresses/", _networkDir(), "/SpendModule.json");
    }

    /**
     * @dev Every key the v2 record can hold. Kept explicit so the whole file is rewritten intact.
     *
     *      **A key absent from this list is silently dropped**, because `saveAddress` rebuilds the
     *      whole file from it rather than patching one entry. So adding a deployed contract means
     *      adding it here in the same change, or the address is recorded nowhere and the next
     *      script cannot find it.
     */
    function _recordKeys() private pure returns (string[10] memory) {
        return [
            "SolidPriceProviderV2Implementation",
            "SpendingLimitLibV2",
            "SolidCreditMathLib",
            "SolidCashConfigLib",
            "SolidCashModuleV2Setters",
            "SolidCashModuleV2",
            "SolidLiquidator",
            "ChainlinkQuoteAdapter",
            "SolidSpendLens",
            "SettlementTreasury"
        ];
    }

    /**
     * @notice Records a deployed address so later scripts read it instead of it being pasted in.
     * @dev Skipped unless actually broadcasting, so a `--fork-url` rehearsal never overwrites the
     *      real record with fork addresses.
     */
    function saveAddress(string memory name, address value) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log(string.concat("  (dry run, not recorded) ", name), value);
            return;
        }

        string memory obj = "spendModuleV2Record";
        string[10] memory keys = _recordKeys();
        string memory json;

        for (uint256 i = 0; i < keys.length; ++i) {
            bool isTarget = keccak256(bytes(keys[i])) == keccak256(bytes(name));
            address entry = isTarget ? value : readAddress(keys[i]);
            if (entry == address(0)) continue;
            json = vm.serializeAddress(obj, keys[i], entry);
        }

        require(bytes(json).length > 0, "nothing to record");

        vm.createDir(string.concat("deployments/addresses/", _networkDir()), true);
        vm.writeFile(
            deploymentPath(),
            string.concat(
                '{\n  "network": "',
                _networkDir(),
                '",\n  "chainId": ',
                vm.toString(block.chainid),
                ',\n  "contractAddresses": ',
                json,
                "\n}\n"
            )
        );
        console.log(string.concat("  recorded ", name), value);
    }

    function _read(string memory path, string memory name) private view returns (address) {
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        string memory key = string.concat(".contractAddresses.", name);
        if (!vm.keyExistsJson(json, key)) return address(0);
        return vm.parseJsonAddress(json, key);
    }

    /// @notice A previously deployed v2 address, or `address(0)` when absent.
    function readAddress(string memory name) internal view returns (address) {
        return _read(deploymentPath(), name);
    }

    /// @notice An address from the **v1** record — the live module, provider proxy and authority.
    function v1Address(string memory name) internal view returns (address) {
        return _read(v1DeploymentPath(), name);
    }

    /// @notice A v2 address, failing with the step that produces it.
    function requireAddress(string memory name, string memory producedBy) internal view returns (address) {
        address value = vm.envOr(name, readAddress(name));
        require(value != address(0), string.concat(name, " not found - run ", producedBy, " first"));
        return value;
    }

    /// @notice A v1 address, env-overridable, failing loudly when neither is present.
    function requireV1Address(string memory name) internal view returns (address) {
        address value = vm.envOr(name, v1Address(name));
        require(value != address(0), string.concat(name, " not found in ", v1DeploymentPath()));
        return value;
    }

    // ========================================= HELPERS =========================================

    /// @dev Fails loudly rather than letting a later call decode empty returndata as a revert.
    function requireHasCode(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " has no code on this chain"));
    }

    /// @dev Logs a 6-decimal USD amount as `<label>: <whole>.<6dp> USD`.
    function logUsd(string memory label, uint256 amount) internal pure {
        uint256 fraction = amount % 1e6;
        string memory padded = vm.toString(fraction);
        while (bytes(padded).length < 6) {
            padded = string.concat("0", padded);
        }
        console.log(string.concat(label, ": ", vm.toString(amount / 1e6), ".", padded, " USD"));
    }

    /// @notice The parameter set, assembled once so the deploy script and the verifier cannot drift.
    function params() internal pure returns (Params memory) {
        return Params({
            maxPerTxUsd: MAX_PER_TX_USD,
            maxDailyLimitUsd: MAX_DAILY_LIMIT_USD,
            maxMonthlyLimitUsd: MAX_MONTHLY_LIMIT_USD,
            defaultDailyLimitUsd: DEFAULT_DAILY_LIMIT_USD,
            defaultMonthlyLimitUsd: DEFAULT_MONTHLY_LIMIT_USD,
            maxDebtPerSafeUsd: MAX_DEBT_PER_SAFE_USD,
            maxGlobalDebtUsd: MAX_GLOBAL_DEBT_USD,
            maxForcedSpendUsd: MAX_FORCED_SPEND_USD,
            dustFloorUsd: DUST_FLOOR_USD,
            minPositionUsd: MIN_POSITION_USD,
            targetLtvBps: TARGET_LTV_BPS,
            closeFactorBps: CLOSE_FACTOR_BPS,
            maxAdjustmentBps: MAX_ADJUSTMENT_BPS,
            modeDelay: MODE_DELAY,
            limitRaiseDelay: LIMIT_RAISE_DELAY,
            collateralWithdrawDelay: COLLATERAL_WITHDRAW_DELAY,
            liquidationGracePeriod: LIQUIDATION_GRACE_PERIOD,
            graceFloorHf: GRACE_FLOOR_HF,
            paramChangeDelay: PARAM_CHANGE_DELAY,
            limitWaiveDelay: LIMIT_WAIVE_DELAY
        });
    }
}
