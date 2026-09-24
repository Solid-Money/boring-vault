# Solid card spend module — Forge deployment

Forge equivalents of the Hardhat scripts in [`scripts/spend-module/`](../../scripts/spend-module/).
Both paths write the same record to `deployments/addresses/<Network>/SpendModule.json`, so they are
interchangeable — deploy with one, verify or operate with the other.

Phase 1 targets Fuse (122) with soUSD as the only spendable asset. USDC gets a price feed because
soUSD's accountant is denominated in it, not because it is spendable.

## Files

| File | Purpose |
| --- | --- |
| `SpendModuleConfig.sol` | Parameters, keys, and the on-disk deployment record. One place per value. |
| `SpendModuleVerifier.sol` | Read-back checks, shared by the deploy script and the standalone verifier. |
| `DeploySpendModule.s.sol` | Deploy + configure + hand over + verify, in one run. |
| `VerifySpendModule.s.sol` | Verification alone, against an existing deployment. Reverts on failure. |
| `HandOverOwnership.s.sol` | Only needed if the deploy ran with `SKIP_HANDOVER`. |
| `AllowSpendToken.s.sol` | Onboard an additional spendable asset (feed + allowlist together). |
| `UpgradeSolidPriceProvider.s.sol` | New provider implementation, with a price-regression gate. |

## Why this is one script, not nine

The Hardhat chain is nine numbered invocations because each is a separate Node process. Forge has no
such constraint, so `DeploySpendModule.s.sol` does the whole sequence at once. That is the reason to
prefer this path:

- **The whole sequence can be rehearsed.** `--fork-url` runs deploy, configuration, handover and
  verification against real Fuse state, including the live soUSD accountant, without broadcasting.
  Nothing is recorded during a dry run, so a rehearsal cannot overwrite the real address record.
- **It completes or reverts as a unit.** No half-configured module: an unpriceable feed or a default
  limit above an org ceiling reverts before anything is live.

The tradeoff is granularity. If you need to redo one step against an already-deployed system, use the
Hardhat script for that step, or `AllowSpendToken` / `HandOverOwnership` here.

## Environment

Three have no safe default and the script refuses to run without them:

| Var | Why it matters |
| --- | --- |
| `SETTLEMENT_TREASURY` | **Immutable in the module.** The only address `spend` can ever send to. Wrong value means a redeploy *and* a re-consent transaction from every registered Safe. |
| `SPENDER` | Backend sweep key. Gets `SPENDER_ROLE` and nothing else. |
| `GUARDIAN` | Pause key. Deliberately not the spender. |

Optional: `OWNER` (defaults to the multisig constant in `SpendModuleConfig`), `PRICE_ADMIN`,
`EXISTING_AUTHORITY`, `SKIP_HANDOVER`.

Set `PRICE_ADMIN` — leaving it unset puts day-to-day feed configuration and the power to replace the
provider implementation over live user funds on the same key. The script warns when it does.

## Running

```bash
# Rehearse against real Fuse state. Nothing broadcast, nothing recorded.
SPENDER=0x.. GUARDIAN=0x.. SETTLEMENT_TREASURY=0x.. \
  forge script script/spend-module/DeploySpendModule.s.sol --fork-url $FUSE_RPC_URL -vvv

# Deploy.
SPENDER=0x.. GUARDIAN=0x.. SETTLEMENT_TREASURY=0x.. PRICE_ADMIN=0x.. \
  forge script script/spend-module/DeploySpendModule.s.sol \
  --rpc-url fuse --broadcast --slow -vvv

# Verify later, any time.
SPENDER=0x.. GUARDIAN=0x.. \
  forge script script/spend-module/VerifySpendModule.s.sol --rpc-url fuse -vvv
```

### Ordering constraints, enforced not just documented

- **Feeds before the module.** The module's constructor takes the provider, and `setPriceProvider`
  only checks for the zero address — a provider that cannot answer `priceUsd` reverts every spend
  *and* every view until the owner corrects it. The script asserts every feed is usable before
  wiring it in.
- **Feeds are internally ordered.** A `VEDA_ACCOUNTANT` feed reverts with `BaseAssetNotConfigured`
  unless its base already has one, so USDC precedes soUSD.
- **Org ceilings before defaults.** `registerSafe` checks a Safe's caps — chosen or defaulted —
  against the live ceilings, so a default above a ceiling makes every registration revert.
- **Grant before renounce on the provider.** Renouncing the deployer's `DEFAULT_ADMIN_ROLE` first
  would leave the proxy permanently unadministrable and un-upgradeable.
- **Module ownership last.** It gates redoing any of the rest.

## What verification checks

Wiring, pricing, the allowlist, caps and ownership, plus three things no single contract enforces:

- **The spender cannot widen its own bounds.** `requiresAuth` on `SolidCashModule` is uniform across
  `spend`, the guardian functions and every `set*`, so the documented role separation lives entirely
  in the authority's capability table. It asserts `SPENDER_ROLE` cannot reach `setOrgCaps`,
  `allowSpendToken`, `setPriceProvider` or `setDefaultLimits`, and that no role can reach the
  inherited `transferOwnership` or `setAuthority` — both live, `transferOwnership` under
  `requiresAuth`.
- **`lens.availableToSpend` does not revert.** That single `eth_call` is the whole authorize path,
  and its per-token `balanceOf` / `priceUsd` reads are unguarded — one bad allowlisted asset declines
  every user's card, not only the holder's. It calls the lens against a codeless address (the
  counterfactual-Safe case) and logs the gas.
- **Module and provider agree on a token's decimals.** `allowSpendToken` reads decimals from the
  token but never cross-checks the provider's cached value, despite the shared
  `TokenDecimalsMismatch` error name.

It reverts on any failure, so it gates the deploy script and can gate a release.

## Upgrades

`UpgradeSolidPriceProvider.s.sol` deploys a new implementation, switches the proxy, and then reverts
the whole script if any allowlisted token stops pricing inside the module's band or moves more than
1% across the upgrade. The module's band is what makes a hostile or buggy provider implementation
survivable, so that is the check worth gating on.

**It does not validate storage layout.** `openzeppelin-foundry-upgrades` is vendored in `lib/` but
needs `ffi = true` plus `build_info`/`ast` output, which this repo does not enable. The Hardhat path
does validate layout via the OpenZeppelin hardhat-upgrades plugin — treat that as authoritative for a
real upgrade and use this for rehearsal or to produce the calldata (`CALLDATA_ONLY=1`).

## After deploying

The module is inert until a Safe opts in. Safe 1.4.1 has no module-setup callback, so enabling is an
owner-signed batch:

1. `Safe.enableModule(SolidCashModule)`
2. `SolidCashModule.registerSafe(dailyLimitUsd, monthlyLimitUsd, timezoneOffset)` — called **by the
   Safe**, passing 0 for either limit to take the org default.

The backend needs `SolidCashLens` (authorize reads) and `SolidCashModule` (settlement). One caveat:
`SpendAvailability` carries both `limitRemainingUsd`, clamped to the live org ceilings, and `limit`,
which is raw per-Safe state and is not. Compute headroom from `limitRemainingUsd`.
