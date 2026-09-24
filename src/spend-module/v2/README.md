# SolidCashModuleV2 — Phase 3 credit line

Spec: `~/.claude/plans/wirex-cash-phase3-credit-line.md`

Reviews, both fully addressed in this tree:

- First pass, 19 findings: `https://claude.ai/code/artifact/cdfa5429-d390-44ae-aeea-58d31b8ff3d8`
- Second pass, Sept 2026, 8 findings including the forced-spend liquidation route. Remediation plan
  and the decisions behind it: `~/.claude/plans/wirex-cash-v2-security-remediation.md`. Summarised
  at the bottom of this file.

## Files

| File | Runtime | Role |
|---|---|---|
| `SolidCashStorageV2.sol` | abstract | **The only place a storage slot is declared.** Both halves inherit it, which is what makes the core's `delegatecall` into the setters safe. Also holds the shared internals. |
| `SolidCashModuleV2.sol` | 23,985 B | Core. Everything that moves value on the authorize path: `spend`, `spendCredit`, `bookForcedSpend`, `adjustBookedSpend`, `reverseSpend`, `liquidate`, Safe-owner actions, decision primitives. |
| `SolidCashModuleV2Setters.sol` | 24,243 B | Configuration, the repay surface, and the reads neither of those needs. Never called directly (`onlyViaCore`); reached through the core's fallback. |
| `SolidLiquidator.sol` | 3,031 B | **The only holder of `LIQUIDATOR_ROLE`.** Forwards everything it seizes to `settlementTreasury` in the same transaction, so a liquidation cannot pay whoever triggered it. |
| `SolidSpendLens.sol` | 12,929 B | Cohort-aware single-`eth_call` read for the authorize path. Serves v1 and v2 Safes. |
| `SolidPriceProviderV2.sol` | — | UUPS upgrade of the live provider: `EXTERNAL_ADAPTER`, `STABLE_ADAPTER`, `priceUsdDetailed`. |
| `SpendingLimitLibV2.sol` | 4,739 B | **Linked library.** `public` variant of `SpendingLimitLib`. |
| `SolidCreditMathLib.sol` | 1,565 B | **Linked library.** Pure liquidation and repay arithmetic. |
| `SolidCashConfigLib.sol` | 4,468 B | **Linked library.** Configuration bounds, the risk-increasing classifier, and the two bounded external reads both halves need. |

Which half a function lives in is an EIP-170 decision, not a semantic one, and the fallback makes it
invisible to callers — always call the **core's** address. Reads resolve through the fallback under
`staticcall` exactly the way a write does.

## Deployment

Scripts and the full runbook: [`script/spend-module/v2/`](../../../script/spend-module/v2/README.md).

It is five steps, not one, because one of them mutates a contract the **live v1 cohort** depends on
and two are executed by the owner multisig rather than a deployer EOA:

| | Step | Key | Touches live v1? |
| --- | --- | --- | --- |
| A | Upgrade the price provider implementation | `UPGRADER_ROLE` | **yes** |
| C | Deploy both halves, configure, hand over | any deployer EOA | no |
| D | Grant v2's capabilities on the authority | OWNER multisig | no |
| E | `sealSetters()` | OWNER multisig | no |
| F | Verify | anyone | no |

Three things about the shape of that:

**The authority is v1's, reused.** It was handed to the multisig at v1 deploy, so a fresh deployer
cannot grant on it — which is why D is its own step. v1's existing grants are never revoked; the same
backend key serves both cohorts.

**Both halves must be constructed with identical `treasury` and `v1Module`.** Immutables are baked
into each contract's own bytecode, so a `delegatecall` into the setters reads the *setters'* copies.
`setSettersImpl` enforces it rather than trusting it, and the verifier re-checks from outside by
calling the setters directly.

**Three libraries must be linked.** They have `public` functions, so deploying either half without
linking fails; there is no runtime fallback. Deploy them once and pass `--libraries` explicitly
rather than letting `forge script` auto-deploy them, so the bytecode is reproducible.

### Step E is not optional

Until `sealSetters()` runs, `setSettersImpl` is a `delegatecall` target that can replace the module's
behaviour and move every escrowed token — which is not compatible with the "non-upgradeable,
deliberately" claim in the core's header. It is `owner`-only rather than `requiresAuth` precisely so
the authority cannot grant it, and sealing removes it from the owner too.

It is deliberately *not* part of step C: everything reachable only through the setters half should be
exercised against the real deployment before the ability to replace that half is given up. Soak, then
seal. Sealing freezes the implementation, not the configuration it exposes.

### Provider upgrade: the pegs stay bare, deliberately

A `STABLE` entry with no `source` is a bare peg, and a bare peg is the one price no band can filter
— the only value it can return is the constant a human already placed inside the band — while
`updatedAt = block.timestamp` makes every staleness bound pass by construction. Both defensive
layers are inert for it.

An earlier revision closed that by requiring a Supra pair on every new peg. **Supra is deprecated on
Fuse**, and nothing else on the chain can replace it: there is no Pyth (zero code at all four of its
common addresses) and no Chainlink, and a DEX quotes a *ratio* rather than a dollar in any case —
the entire Algebra DEX holds roughly $78k of stablecoin depth, with its deepest genuinely two-sided
pool at ~$20k.

So the two live bare pegs stay, and the reason that is sound is a scope decision rather than a
mitigation: **only Solid's own assets are collateral.** USDC.e and USDT are spendable and nothing
else (`_stableConfig`), so an uncorroborated peg is only ever used to value a single settlement,
bounded by `maxPerTxUsd` — never to size credit against a `maxGlobalDebtUsd` book. USDC.e is
additionally configured on the provider as soUSD's accountant base, the unit the vault's NAV is
already denominated in, so quoting it at exactly $1.00 asserts nothing the accountant does not
already assert.

That argument covers valuing a settlement. It does **not** cover accepting a token as payment, and
the two used to be conflated. `_sizeRepay` uses a token's price to decide how much *debt* an
incoming payment retires, so a bare peg accepted as tender would let a borrower settle a dollar of
debt with a token trading at ninety cents. `repayTender` is therefore a separate, narrower list:
soUSD (accountant-priced) and USDC.e (that accountant's own base). **USDT is spendable and is not
tender.** `repayFromCollateral` is exempt, because it spends the borrower's own escrowed balance
and prices it as collateral rather than accepting it as payment.

`repayFromCollateral` is at par unless the owner sets a per-token fee with
`setCollateralRepayFee(token, feeBps)`. Unset is zero. The fee is debited from escrow on top of
the collateral the credit is worth, goes to `settlementTreasury` in the same transfer, and never
changes the debt retired. It is held strictly below that token's `liquidationBonusBps`, both when it
is set and again at use, since lowering the bonus applies immediately. That keeps self-deleverage
cheaper than liquidation, and keeps `(1+f)T < 1`, so the operation still cannot worsen a healthy
position.

**At launch this system contains no market observation at all**, and therefore no oracle to be
wrong. That is the whole credit book backed by one asset whose value comes from an accountant this
system already has to trust.

What replaces Supra when that changes:

- `setTokenConfig` **refuses to create another bare peg** (`UncorroboratedPeg`). The day a stablecoin
  becomes *collateral* it needs a `STABLE_ADAPTER` feed — and its LTV is 0, so `validateTokenConfig`
  reverts unless that promotion is made explicitly. Both are enforced rather than remembered.
- `STABLE_ADAPTER` quotes `min(peg, observed)` — an allowlisted adapter may mark a peg **down but
  never up**. A compromised adapter therefore costs users borrowing power instead of inflating
  collateral, and an unusable one degrades to the peg rather than declining every card composed on
  top of it.
- `EXTERNAL_ADAPTER` is the price-*setting* family, for WETH and for a non-USD peg such as EURC
  (whose USD price floats with EUR/USD, so the adapter composes `peg_EUR x EURUSD`).
- `setBarePeg` exists at `UPGRADER_ROLE` for the one case `setTokenConfig` cannot serve: a fresh
  deployment has no legacy entry to inherit, and soUSD cannot be configured until its accountant base
  is.

## Price bands — the ceiling drifts

`minPriceUsd` and `maxPriceUsd` are this module's own band, independent of the provider's. Two
things about the ceiling matter:

- **A price above the effective ceiling is CAPPED for quoting and REFUSED for settlement.** Capping
  is only safe where a price multiplies a balance to produce a value; where it divides a USD
  obligation to produce a token amount, an understated price takes more of the user's tokens, so
  those paths revert instead.
- **Because of that, a static ceiling on an appreciating asset is a total outage with a computable
  date**, not a graceful degradation: soUSD only goes up, and above the ceiling debit settlement,
  collateral locking, all three repay paths and liquidation all refuse at once. So the ceiling is
  quoted at `ceilingAnchor` and rises at `ceilingGrowthPerSec` (1e-18 USD-6dp units per second,
  capped at 100%/yr of the anchored ceiling). What it bounds is the *rate of change*, which is what
  a bad print has to beat — rather than a level that honest yield beats on its own.

`ceilingGrowthPerSec = 0` is a static ceiling and remains correct for anything not expected to
appreciate. Set it for soUSD and soETH; leave it at zero for stablecoins.

Set the module's band and the provider's band to **different** values, with the module's as the
outer backstop. Configured identically they are one layer, not two — which was a standing finding
against v1.

## Limits, and the admin waiver

Six bounds apply, and they are **not** all the same kind of thing:

| Bound | Scope | Waivable | Why |
|---|---|---|---|
| `maxPerTxUsd` | per transaction | **yes** | Policy: how much Solid lets one swipe be |
| `SpendingLimit` rolling daily / monthly | per Safe, org-clamped | **yes** | Policy |
| `maxDebtPerSafeUsd` | per Safe | **yes** | Policy: one user's credit allowance |
| `maxForcedSpendUsd` | per `bookForcedSpend` call | **no** | A mandatory authorization is a real card transaction and is bounded like one |
| `maxGlobalDebtUsd` | whole book | **no** | Solid's float solvency, not a user allowance |
| collateral / borrowing power | per Safe | **no** | The user's own solvency |

`limitsWaived(safe)` is the single predicate, checked in `_bookOperation` and `_requireDebtCaps`.

All four waiver entry points are `requiresAuth` (admin) and **the Safe does nothing** — no owner
signature, no passkey prompt, no registration change. A Safe only has to already be registered,
which it is from onboarding.

```
requestWaiveSafeLimits(safe)   -> effective after limitWaiveDelay     (prefer this)
restoreSafeLimits(safe)        -> IMMEDIATE
requestWaiveLimits()           -> effective after paramChangeDelay    (whole book)
restoreLimits()                -> IMMEDIATE
```

**Two delays, because the blast radii differ.** A per-Safe waiver is bounded by that one account's
own balance and collateral, so it runs on `limitWaiveDelay` — set it to 0 for an immediate waiver if
ops needs that responsiveness. The org-wide waiver lifts the caps for **every** registered Safe at
once, which is the on-chain backstop against a compromised spender key, so it keeps the higher bar
of `paramChangeDelay`.

`limitWaiveDelay` is deliberately *not* `paramChangeDelay`: that one is floored by
`liquidationGracePeriod`, so sharing it would mean buying a fast operational waiver by shortening the
window that protects users from a bad oracle print.

Three properties worth knowing before using it:

- **Waiving is delayed, restoring is immediate.** The waiver is stored as an activation timestamp
  rather than a boolean, so there is no representation for "waived right now" — the delay is
  inherent, and the window is when anyone watching the event can object.
- **Spend is still recorded while waived** (`SpendingLimitLibV2.recordSpend`), so lifting a waiver
  does not hand the user a fresh daily window, and reported volume stays true throughout.
- **The org-wide waiver removes the on-chain backstop against a compromised spender key for every
  registered Safe at once.** Prefer the per-Safe form wherever the need is one account.

Replay protection is never waivable: it is correctness, not policy. It is keyed on
`BookedSpend.exists`, a dedicated bit, rather than on a non-zero amount — an amount is writable by
`adjustBookedSpend`, and a marker must not be.

**Re-registering is not a way around any of this.** The `SpendingLimit` lives outside `SafeConfig`,
so `deregisterSafe`'s `delete` cannot reach it: a returning Safe keeps `spentToday` and
`spentThisMonth`, and `reinitialize` clamps its caps down to the ones it left with. Raising them
still goes through `requestSpendingLimitIncrease` and `limitRaiseDelay`.

## Liquidation is Solid-only, and cannot pay whoever triggers it

`liquidate` is `requiresAuth`. `LIQUIDATOR_ROLE` is held by exactly one address — `SolidLiquidator`
— and that contract forwards every token it receives to `settlementTreasury` inside the same
transaction. The key that drives it is `LIQUIDATION_OPERATOR_ROLE`, deliberately neither spender key.

The reason is a composition, not a worry about liquidators. `bookForcedSpend` can create debt with
no collateral behind it, because a mandatory card authorization has already happened off-chain and
refusing to record it is worse than recording it. While anyone could liquidate, those two facts
were a complete theft: a compromised `CREDIT_SPENDER_ROLE` key books unbacked debt against any
registered Safe, then liquidates the position it just manufactured and keeps the collateral plus
`liquidationBonusBps`.

Closing that at the debt end would mean capping what one mandatory authorization may be, which the
card flow cannot accept. So it is closed at the extraction end. Manufacturing a liquidation now
needs two independent compromises, and even with both the proceeds land in Solid's own treasury,
where `reverseSpend` plus a refund make the user whole.

Three consequences worth stating:

- **Third-party liquidators are gone.** None were expected on Fuse, and Solid was always the
  realistic liquidator of last resort — the same reasoning that left `repayFromCollateral` ungranted.
- **`SolidLiquidator` needs a float** of whatever it repays with, funded by the treasury. `sweep` is
  permissionless and returns it, because the destination is fixed at construction.
- **`pokeHealth` stays permissionless.** It starts a clock and never authorises a seizure, so
  leaving it open means grace begins when a position went bad rather than when Solid looked.

## Circuit breakers

Three, with deliberately different reach. None of them can be bypassed by a spend path.

| Switch | Owner | Stops | Deliberately does not stop |
|---|---|---|---|
| `pause()` / `setSafePaused` | guardian | `spend`, `spendCredit`, `bookForcedSpend`, **and raising a booked spend** | repay, deleverage, withdrawal, liquidation |
| `setTokenPaused` | guardian | selling, locking, and **accepting that token as repayment** | counting toward liquidation capacity |
| `setLiquidationsPaused` | guardian | `liquidate` | everything else, so a position can still be rescued |

On a suspected spender-key compromise the guardian pulls **both** `pause()` and
`setLiquidationsPaused(true)`. The first stops new bookings; only the second stops value leaving
positions that were booked before anyone noticed. Pausing alone leaves the extraction path open.

`tokenPaused` lives in its own mapping, not in `TokenConfig`. Every function that rewrites a token's
configuration writes the whole struct, so a `paused` field inside it was cleared by any config
authored before the incident — including by the permissionless `commitTokenConfig`.

`setLiquidationsPaused` exists because nothing else could do its job. `setTokenPaused` is
capacity-preserving by design — so that a guardian action can never *manufacture* a liquidation —
which is also why it can never stop one, and tightening `minPriceUsd` is classified risk-increasing
and waits out `paramChangeDelay`. A price wrong in the *low* direction had no immediate answer.

## Delays cannot be zeroed

`setParams` has no delay of its own, so without floors it could zero every delay in one transaction
and apply any risk-increasing change in the next. Three rules close that:

- `liquidationGracePeriod >= MIN_LIQUIDATION_GRACE` (10 minutes)
- `graceFloorHf <= MAX_GRACE_FLOOR_HF` (0.98). At 1.0 every unhealthy position is below the floor by
  definition, so the grace period would have no band left to apply in — a one-parameter bypass of
  the same kind the delay floors exist to close
- `collateralWithdrawDelay >= MIN_COLLATERAL_WITHDRAW_DELAY` (1 minute)
- `paramChangeDelay` can be **raised** by `setParams` but never lowered by it. Lowering goes through
  `requestParamChangeDelayReduction` and waits out the current `paramChangeDelay` — the window it is
  about to remove is the window in which the removal can be objected to.

`targetLtvBps` is capped at 9,500 for a separate reason: sizing collateral at a token's full LTV
opens every position exactly at its bound, where one unit of rounding decides whether a credit spend
succeeds.

### Two delays ship at zero

`modeDelay` and `limitRaiseDelay` are both **0** at launch, and the reason is the same for each:
there is no countdown anywhere in the app. A non-zero value works correctly — the user signs, nothing
observable changes, and no screen explains why or says when it will stop. An unexplained delay is a
worse failure than no delay. `limitRaiseDelay` additionally matches v1's live value, so the same user
action does not behave differently either side of a migration the user cannot see.

What that gives up is real: the window in which a switch or a raise nobody intended could be
cancelled. Both cancellation paths already exist — `setMode` with the mode you are already in, and
`cancelPendingSpendingLimitIncrease` — and start working the instant either delay is non-zero.

One asymmetry worth knowing: `0` means *next block* for a limit raise and *same block* for a mode
switch, because `getCurrentLimit` matures a pending increase on `>` while `_currentMode` matures a
mode switch on `>=`. Nothing in the app does both in one transaction; a backend script might.

## Size budget

`SolidCashModuleV2` has **804 bytes** of margin against EIP-170; the setters half has **363**. Both
are effectively full. (`setCollateralRepayFee` was paid for by moving solmate's `requiresAuth` check
out of the modifier into one internal `_requireAuth`. A modifier is inlined at every use, so the
revert-string check had been emitted once per admin function. The revert data is unchanged.)
Any addition needs a corresponding removal, a move to the other half, or a move into one of the
three linked libraries — which is where four things already went for exactly
this reason: configuration validation, the risk classifier, the bounded provider read, and the
spending-limit round trips (three `delegatecall`s with an eleven-field struct each, collapsed into
one).

Adding a field to `TokenConfig`, `BookedSpend` or `Params` is much more expensive than it looks: the
coder for it is emitted at every site that touches the struct, in both halves.

## What has and has not been verified

- **Compiles clean** under solc 0.8.21, London, optimizer 200 runs. No warnings.
- **Both halves fit EIP-170**, measured from a cold `out/` and `cache/` over the whole repo. Measure
  it that way: `forge build --sizes --contracts src/spend-module` narrows the compilation unit and
  reports both halves a couple of hundred bytes *smaller* than a deployer will actually get, which at
  this margin is the difference between fitting and not. (`LiquidBeraEthDecoderAndSanitizer` is over the limit in this repo and
  is unrelated to this work.)
- **No tests have been run.** Nothing here is behaviourally verified. Three suites now exist and
  compile — `ForcedSpendExtraction.t.sol`, `TenderAndHealth.t.sol` and `ConfigAndAuth.t.sol`, over a
  shared `V2Fixture` — covering every finding of the Sept 2026 review, including an end-to-end case
  that grants an attacker both the credit-spender and liquidation-operator roles and asserts their
  balance is unchanged. **Written, not executed.** The invariant, fuzz and fork suites in the spec's
  §10 remain the gate before this goes anywhere near a testnet, let alone an audit.

## Sept 2026 review — what changed

The second review (see the artifact linked at the top) found eight further issues, all addressed
here. The one that mattered was a composition rather than a single bug: `bookForcedSpend` creates
debt with no collateral behind it, liquidation was permissionless, and a deep shortfall skipped the
grace period — so one compromised `CREDIT_SPENDER_ROLE` key could book unbacked debt against any
Safe and immediately seize its collateral at a 5% bonus.

| # | Finding | Fix |
|---|---|---|
| 1 | Forced spend → self-liquidation | `liquidate` whitelisted to `SolidLiquidator`; forced spend honours mode and the per-Safe debt cap; forced debt never takes the `graceFloorHf` shortcut; grace raised to 1 day |
| 2 | `isRiskIncreasing` flagged a *raised* liquidation threshold | Comparison flipped — lowering it is what makes positions seizable |
| 3 | Bare-peg stables accepted at par as repayment | `repayTender`, narrower than `spendable` |
| 4 | Health stamp written from an unpriced position | `_healthFactor` reports `fullyPriced`; the stamp is only set when it is true |
| 5 | `transferOwnership` / `setAuthority` grantable pre-seal | Overridden to owner-only |
| 6 | `graceFloorHf` could be set to 1.0 | Capped at `MAX_GRACE_FLOOR_HF` |
| 7 | Adjustment increases ignored both pauses | `_requireNotPaused` on the increase branch |
| 8 | `abi.decode(bool)` on Safe-controlled return data | Raw word compared against 1 |
