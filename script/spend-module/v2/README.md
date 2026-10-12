# SolidCashModuleV2 — Forge deployment

Phase 3 adds the credit line. It is **not** a replacement deployment: v1 stays live, migration is
per-user with no deadline, and both cohorts share one price provider, one authority, one settlement
treasury and one backend spender key.

That sharing is what shapes this runbook. Two of the six steps mutate contracts the live v1 cohort
depends on, and two are executed by the owner multisig rather than a deployer EOA — so this is not
one script, and the one script that does exist refuses to guess on the others' behalf.

| File | Purpose |
| --- | --- |
| `SpendModuleV2Config.sol` | Parameters, keys, token risk, feeds, and the on-disk record. One place per value. |
| `SpendModuleV2Verifier.sol` | Read-back checks, shared by the deploy script and the standalone verifier. |
| `UpgradePriceProviderV2.s.sol` | **Step A.** New provider implementation, with a v1 price-regression gate. |
| `DeploySpendModuleV2.s.sol` | **Step C.** Deploy both halves and `SolidLiquidator`, configure, hand over. |
| `SealSettersV2.s.sol` | **Step E.** Close the upgrade hatch. Permanent. |
| `VerifySpendModuleV2.s.sol` | **Step F.** Assert everything, any time. |

Addresses land in `deployments/addresses/<Network>/SpendModuleV2.json`. v1's record is read, never
written: v1's `saveAddress` re-serialises its file from a fixed key list, so a v2 key written into it
would be silently dropped the next time any v1 script ran.

## The six steps, and who runs each

| | Step | Key | Touches live v1? |
| --- | --- | --- | --- |
| A | Upgrade the price provider implementation | `UPGRADER_ROLE` | **yes** |
| B | Corroborate the USDC and USDT pegs | `PRICE_ADMIN_ROLE` | **yes** |
| C | Deploy v2, configure it, hand it over | any deployer EOA | no |
| D | Grant v2's capabilities on the authority | OWNER multisig | no |
| D2 | Fund `SolidLiquidator` with tender float | TREASURY | no |
| E | `sealSetters()` | OWNER multisig | no |
| F | Verify | anyone | no |

**On the live Fuse deployment, A, B, D and E are all the same key.** `UPGRADER_ROLE` and
`PRICE_ADMIN_ROLE` both sit on the owner multisig `0xBA308f29…1F29`, which also owns the authority
and will own the module. So only **C** is a deployer EOA; everything else is a multisig batch, and
every one of those scripts takes `CALLDATA_ONLY=1` to produce the payload without sending.

A and B come first because C asserts both have landed — deploying against a provider that cannot
answer would produce a module whose every credit path reverts.

## Environment

No safe default, required:

| Var | Why it matters |
| --- | --- |
| `SPENDER` | Backend sweep key. Already holds `SPENDER_ROLE` for v1 — the same key serves both cohorts. |
| `GUARDIAN` | Pause key, on both modules. **Must be its own key** — the script refuses otherwise, because a brake wired to the thing it stops is not a brake. |
| `LIQUIDATION_OPERATOR` | Drives `SolidLiquidator`. **Must not be either spender key** — the script refuses otherwise. A manufactured liquidation needs `CREDIT_SPENDER` to create the debt and this key to realise it, and that is only two compromises while these are two keys. The guardian is an acceptable holder. |

Optional: `OWNER` (defaults to the multisig constant), `SETTLEMENT_TREASURY` (defaults to v1's
recorded treasury — **immutable in both halves**, so a wrong value is a redeploy plus a re-consent
transaction from every registered Safe), `SKIP_HANDOVER`, `CALLDATA_ONLY`,
and the three library addresses below.

Optional: `CREDIT_SPENDER`, which **defaults to `SPENDER`**.

Separate spender keys are preferred, not required. What is permanent is the **role** split: this
module is not upgradeable, so once `spend` and `spendCredit` are gated on one role nothing can ever
separate them again. The **key** assignment is the opposite — a grant on the shared
`FuseRolesAuthority`, reversible in either direction by the owner multisig, any time.

Today one key is the honest configuration. The backend has a single `CASH_SPENDER_PRIVATE_KEY` in
one service, with `CASH_SPENDER_SIGNER: "local"` in prod, so a second address would live in the same
env, in the same pod, behind the same compromise. That is separation on paper, bought with a second
hot key to fund, monitor and rotate. Deploy the roles split, run them merged, and split the keys for
real when the credit path gets its own signer or KMS identity.

**The backend can never repay on a user's behalf.** `repayFromSafe` and `repayFromCollateral` are
gated by `_requireSafeOrCreditSpender`, whose first branch is `msg.sender == safe` — and step D
**deliberately does not grant either selector to any role**. So a user repays or deleverages from
their own Safe, and the backend's job is to notify, never to act. The capability still exists in the
contract, so revisiting it is one `setRoleCapability` from the owner multisig rather than a new
module; the verifier asserts it is absent, so re-enabling it cannot happen quietly.

What that gives up: an unhealthy position has no resolution but `liquidate`, which takes
`liquidationBonusBps` (5%) out of the same collateral a deleverage would have spent at par — and
since `liquidate` is now whitelisted to `SolidLiquidator`, Solid **is** that liquidator rather than
merely likely to be. The 5% is therefore a penalty paid by the user to Solid, not an incentive to a
stranger. Retained at launch as a deliberate decision; it is a config value, so lowering or zeroing
it for soUSD is one `updateToken` away.

What the split is worth when it *is* real: `CREDIT_SPENDER_ROLE` reaches every path that can create
debt and move a user's assets into escrow — including `bookForcedSpend`, the one spend path that
records the rolling limit rather than being enforced by it, so it is bounded only by
`maxForcedSpendUsd` per call and `maxGlobalDebtUsd` overall. Keeping that away from the key that
signs on every card transaction is the point.

Note that the immediate response to a compromised spender key is the **guardian's `pause()`**, which
stops `spend`, `spendCredit` and `bookForcedSpend` together — not role revocation, which needs the
multisig. That is why `GUARDIAN` stays a hard requirement while `CREDIT_SPENDER` does not.

**Pull both brakes, not one.** `pause()` stops new bookings; it does not stop value leaving
positions booked before anyone noticed. `setLiquidationsPaused(true)` is the one that does. On a
suspected credit-spender compromise the guardian calls both, then reverses the bad bookings with
`reverseSpend` inside the one-day grace period.

## Libraries — link them, don't let them float

Three libraries have `public` functions and must be linked:

```
src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2
src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib
src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib
```

`forge script` will auto-deploy them if you say nothing, which is fine for a fork rehearsal and wrong
for production: the addresses land only in the broadcast artifact, a re-run deploys them again, and
the deployed bytecode of both halves differs between runs — which makes source verification and any
later comparison harder than it needs to be.

Deploy them once, record them, then link explicitly:

```bash
forge create src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2 --rpc-url fuse --broadcast
forge create src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib   --rpc-url fuse --broadcast
forge create src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib   --rpc-url fuse --broadcast
```

Then pass all three to step C with `--libraries`, and set `SPENDING_LIMIT_LIB_V2`,
`SOLID_CREDIT_MATH_LIB` and `SOLID_CASH_CONFIG_LIB` so they are written into the record.

## Running it

### Rehearse the whole thing first — one command

```bash
forge script script/spend-module/v2/DeploySpendModuleV2.s.sol --sig "rehearse()" \
  --fork-url $FUSE_RPC_URL --sender $DEPLOYER -vv
```

This runs **A → C → D → handover → E → F** against live Fuse state in a single fork, then asserts
the full verification including the role table and the seal. It impersonates the role holders rather
than broadcasting, which is the only way to rehearse the sequence at all: three of the five steps are
multisig actions, and each separate `--fork-url` invocation starts a fresh fork — so running the
scripts one after another would rehearse each against a chain where the previous step never happened.

There is no step B any more — see below. Everything else is exactly what the individual scripts do.

Nothing is broadcast and nothing is recorded, so a rehearsal cannot touch the real address record.
**Run it after any change to `SpendModuleV2Config.sol`** — it is the only thing that checks the
configuration against the chain it will actually meet.

The individual scripts also take `--fork-url` on their own, which is useful for iterating on one of
them; only step A is meaningful in isolation, since C needs A to have landed.

### Step A — upgrade the provider (`UPGRADER_ROLE`)

```bash
CALLDATA_ONLY=1 forge script script/spend-module/v2/UpgradePriceProviderV2.s.sol \
  --rpc-url fuse --broadcast -vvv
```

Deploys the implementation and prints the `upgradeToAndCall` payload for the multisig. With an EOA
holding `UPGRADER_ROLE`, drop `CALLDATA_ONLY` and it upgrades and then asserts that **every token the
live v1 module allowlists still prices, within 1%** — read back through the v1 module, not the
provider, because the module applies its own band and its own staleness bound on top and it is the
module's answer that decides whether a card works.

Storage layout is not re-checked here; the repo does not enable the `ffi`/`build_info`/`ast` output
the OZ upgrades library needs. The layout was verified by hand (`_adapterAllowed` takes the first
word of the old `__gap`, `pairIndex` lands in the config's existing trailing padding) and the Hardhat
path validates it through the OZ plugin — treat that as authoritative for a production run.

### Step B — removed

There is no longer a step that corroborates the USDC.e and USDT pegs. **Supra is deprecated on
Fuse**, and nothing on this chain replaces it: no Pyth (zero code at all four of its common
addresses), no Chainlink, and a DEX quotes a *ratio* rather than a dollar — the whole Algebra DEX
holds roughly $78k of stablecoin depth.

Both entries therefore stay as the bare pegs the v1 implementation wrote, and step C reports them
rather than refusing. That is sound because **only Solid's own assets are collateral**: USDC.e and
USDT are spendable and nothing else, so an uncorroborated peg is only ever used to value a single
settlement bounded by `maxPerTxUsd`, never to size credit. USDC.e is additionally soUSD's accountant
base — the unit its NAV is already denominated in — so quoting it at $1.00 asserts nothing the
accountant does not already assert. At launch the system contains no market observation at all.

`setTokenConfig` refuses to create another bare peg, so the day a stablecoin becomes a module token
it needs a `STABLE_ADAPTER` feed and a real oracle behind it. That is enforced, not remembered.

### Step C — deploy v2 (any deployer EOA)

```bash
forge script script/spend-module/v2/DeploySpendModuleV2.s.sol \
  --rpc-url fuse --broadcast --slow -vvv \
  --libraries src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2:0x.. \
  --libraries src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib:0x.. \
  --libraries src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib:0x..
```

Deploys the setters half, the core, wires them, sets parameters, allowlists the three assets, sets
the repay-tender list, deploys `SolidLiquidator` and the lens, and transfers ownership to the
multisig. It prints step D's calldata on the way out.

`LIQUIDATION_OPERATOR` is a **required** env var here, alongside `SPENDER` and `GUARDIAN`. Unlike
`CREDIT_SPENDER` it has no default, because defaulting it to a spender key would silently undo the
two-key split that makes a manufactured liquidation unprofitable. The script refuses it if it equals
either spender.

### Step D — grant the roles (OWNER multisig)

Fourteen `setRoleCapability` calls and three `setUserRole` calls, all printed by step C with their
calldata. Every capability targets the **core's** address, including the ones implemented in the
setters half: callers always reach the setters through the core's fallback, so the core is the
`target` the authority is asked about.

**One exception, and it matters.** `LIQUIDATION_OPERATOR_ROLE` is granted over
`SolidLiquidator.liquidate`, so its target is the **liquidator contract**, not the core. The core's
`liquidate` is granted to `LIQUIDATOR_ROLE`, whose only holder is that same contract.

Liquidation is no longer permissionless. `bookForcedSpend` can create debt with no collateral behind
it, because a mandatory card authorization has already happened off-chain, and while anyone could
liquidate those two composed into a complete theft: book unbacked debt against any registered Safe,
then liquidate the position you just manufactured and keep the collateral plus the 5% bonus. Routing
every seizure through a contract that forwards its proceeds to the immutable treasury is what closes
it. Two rules follow, and the deploy script refuses to proceed if either is broken:

- `LIQUIDATOR_ROLE` goes to the **contract**, never to an EOA.
- `LIQUIDATION_OPERATOR` must not be either spender key. That separation is the entire reason a
  manufactured liquidation now needs two independent compromises.

The existing `SPENDER_ROLE` and `GUARDIAN_ROLE` grants for v1 are left alone. **Do not revoke them** —
the v1 cohort is still being served by the same keys.

### Step D2 — fund the liquidator (TREASURY)

`SolidLiquidator` repays out of its own balance, so it needs a float of tender before the first
liquidation; without one, `liquidate` reverts. The float is Solid's own money and `sweep` returns it
to the treasury at any time, permissionlessly, because the destination is fixed at construction.

### Step E — seal (OWNER multisig)

```bash
CALLDATA_ONLY=1 forge script script/spend-module/v2/SealSettersV2.s.sol --rpc-url fuse -vvv
```

**Permanent, and deliberately not part of step C.** Everything reachable only through the setters
half — every repay path, every parameter, the guardian's breakers — should have been exercised
against the real deployment before the ability to replace that half is given up. Soak, then seal.

Sealing freezes the implementation, not the configuration it exposes: parameters, token
configuration, pauses and the limit waivers all keep working afterwards.

Until it runs, the verifier reports the seal as outstanding on every run.

### Step F — verify

```bash
SPENDER=0x.. GUARDIAN=0x.. LIQUIDATION_OPERATOR=0x.. \
  forge script script/spend-module/v2/VerifySpendModuleV2.s.sol --rpc-url fuse -vvv
```

Read-only, reverts on the first failure, safe against production at any time. Run it after step C
(with `SKIP_ROLE_CHECKS=true`), again after D, and again after E.

## What verification checks

Wiring, parameters, the allowlist, ownership and the lens, plus four things no single contract can
enforce:

- **Both halves agree about the immutables.** `setSettersImpl` checks them at wiring time; this
  re-checks from outside by calling the setters *directly*, because a `delegatecall` into them reads
  their own copies.
- **The role table, in both directions.** `requiresAuth` is uniform across `spend`, `spendCredit`,
  the guardian functions and every `set*`, so the whole documented separation lives in the
  authority's capability table and nowhere else. It asserts what each key can reach and — the part
  that matters — what it cannot: the debit spender must not reach `spendCredit` or
  `bookForcedSpend`, the credit spender must not reach `spend` or the limit waiver, the guardian must
  not reach configuration, and no role at all may reach `setSettersImpl`, `transferOwnership` or
  `setAuthority`. Each "cannot" also asserts the key is not the owner, since `Auth.isAuthorized`
  short-circuits for the owner and would make the check vacuously pass.
- **The liquidation split holds.** `LIQUIDATOR_ROLE` reaches `liquidate` and its holder is the
  contract; neither spender key reaches it on the module or through the liquidator; and the
  liquidator's `module` and `settlementTreasury` immutables match the core's. Those immutables are
  what make a seizure unable to pay whoever triggered it.
- **Tender is narrower than spendable.** Every configured tender token is set on chain and nothing
  else is. A token that is spendable but not tender is the surprising direction, so it is printed.
- **Grace is at least a day and the parameter delay covers it**, and `graceFloorHf` is below WAD —
  at WAD the shortcut swallows every unhealthy position and the grace period has no band to apply in.
- **The module's band is not the provider's band.** Identical numbers are one layer, not two — and
  the independent band is the entire argument for tolerating an upgradeable provider. The verifier
  rejects a token whose two bands match exactly.
- **v1 still prices.** The provider is shared and step A upgrades it underneath a live module.

It also reports, without failing: `modeDelay = 0`, `limitRaiseDelay = 0`, a zero borrow APY, an
appreciating asset left on a static ceiling, an unsealed setters implementation, and an ungranted
role table.

## Parameters worth a decision before you run this

Everything is in `SpendModuleV2Config.sol` with its reasoning next to it. Five are genuinely a
business call rather than a derived number:

| Constant | Value | Note |
| --- | --- | --- |
| `MAX_GLOBAL_DEBT_USD` | 250,000 USD | The real rollout throttle. Solid's float, never waivable, checked on every debt-creating path. Open below target and raise it. |
| `MAX_DEBT_PER_SAFE_USD` | 25,000 USD | Per-Safe credit allowance, on top of the collateral requirement. |
| `BORROW_APY_PER_SECOND` | 1_243_680_656 | **4% effective per year**, one rate for every collateral — debt is one USD figure on one global index. The unit is *continuously compounded*, so it is `ln(1.04) * 1e18 / 365 days`, not `0.04e18 / 365 days` (which would charge 4.081%). `setBorrowApyPerSecond` accrues before it writes, so changing it later cannot reprice elapsed time. |
| `MODE_DELAY` | 0 | Switching into Credit is immediate — there is no countdown anywhere in the app, and an unexplained delay is a worse failure than no delay. Raise it when the app grows one. |
| `LIMIT_RAISE_DELAY` | 0 | Matches v1's live value, so the same user action does not behave differently either side of a migration the user cannot see. |
| `STABLE_MIN/MAX_PRICE_USD` | ±2% | Tighter than v1's ±3%, and deliberately not the provider's number. A depeg between 2% and 3% leaves a v1 Safe spending and a v2 Safe declining — the newer cohort held to the tighter bound, not an accident. |

The two zeros give up a real thing: the window in which a switch or a raise nobody intended could be
cancelled. `setMode`'s cancellation path and `cancelPendingSpendingLimitIncrease` both already exist
and start working the instant either delay is non-zero.

One asymmetry to know about: `0` means *next block* for a limit raise and *same block* for a mode
switch — `getCurrentLimit` matures on `>` while `_currentMode` matures on `>=`. Nothing in the app
does both in one transaction; a backend script might.

The soUSD ceiling is **not** a constant. It is computed from the live price at deploy plus 30%
headroom, anchored at that block, and then drifts upward at 25%/yr. A static ceiling on an
appreciating asset is an outage with a computable date — above it, debit settlement, collateral
locking, all three repay paths and liquidation refuse at once.

## Rollback

- **After A:** re-run `UpgradePriceProviderV2.s.sol` pointing at the previous implementation, which
  is recorded as `SolidPriceProviderImplementation` in v1's file. The regression gate runs either way.
- **After B:** `setTokenConfig` again with the previous config. The read path still accepts a bare
  peg, so reverting to one works — it just reinstates the finding.
- **After C, before D:** nothing to roll back. An ungranted module is inert: no key can spend on it,
  and no Safe is registered.
- **After D:** `setUserRole(..., false)` on the authority. Immediate, and it is the fast way to stop
  v2 without touching v1.
- **After E:** there is no rollback. That is what sealing means.
