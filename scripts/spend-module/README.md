# Solid card spend module — deployment

Deploys `SolidPriceProvider`, `SolidCashModule` and `SolidCashLens`, plus the
`FuseRolesAuthority` that governs them.

Phase 1 target is Fuse (chainId 122) with soUSD as the only spendable asset. USDC gets a
price feed because soUSD's accountant is denominated in it, not because it is spendable.

## Before you start

Fill in `config.js`. Four fields have no safe default and the scripts refuse to run without
them:

| Field | Why it matters |
| --- | --- |
| `settlementTreasury` | **Immutable.** The only address `spend` can ever send to. Wrong value means a redeploy *and* a re-consent transaction from every registered Safe. |
| `owner` | Ends up owning the module and the authority, and holding `UPGRADER_ROLE` on the provider. Timelocked multisig in production. |
| `spender` | Backend sweep key. Gets `SPENDER_ROLE` and nothing else. |
| `guardian` | Pause key. Deliberately not the spender. |

Also set `priceAdmin` — leaving it empty puts day-to-day feed configuration and the power to
replace the provider implementation on the same key.

Check `.env` has `PRIVATE_KEY` and `FUSE_RPC_URL`.

## Order

```bash
npx hardhat run scripts/spend-module/00_deploySolidPriceProvider.js --network fuse
npx hardhat run scripts/spend-module/01_configurePriceFeeds.js      --network fuse
npx hardhat run scripts/spend-module/02_deployCashAuthority.js      --network fuse
npx hardhat run scripts/spend-module/03_deploySolidCashModule.js    --network fuse
npx hardhat run scripts/spend-module/04_deploySolidCashLens.js      --network fuse
npx hardhat run scripts/spend-module/05_configureCashRoles.js       --network fuse
npx hardhat run scripts/spend-module/06_configureCashModule.js      --network fuse
npx hardhat run scripts/spend-module/07_verifyDeployment.js         --network fuse
npx hardhat run scripts/spend-module/08_handOverOwnership.js        --network fuse
npx hardhat run scripts/spend-module/07_verifyDeployment.js         --network fuse   # again
```

Or `deployAll.js` for all of it in one go. On a part-way failure, rerun the individual step
rather than `deployAll` — the earlier steps are already deployed and would be deployed twice.

Addresses are written to `deployments/addresses/Fuse/SpendModule.json` as each step
completes, and later steps read them from there. No hand-editing addresses between steps.

### Why this order

- **01 before 03.** The module's constructor takes the provider, and `setPriceProvider` only
  checks for the zero address — a provider that cannot answer `priceUsd` reverts every spend
  *and* every view until the owner fixes it. Step 03 refuses to deploy unless the provider
  already prices every token in the allowlist.
- **Feeds within 01 are ordered.** A `VEDA_ACCOUNTANT` feed reverts with
  `BaseAssetNotConfigured` unless its base already has one, so USDC precedes soUSD.
- **06 sets org ceilings before defaults are usable.** `registerSafe` checks a Safe's caps —
  chosen or defaulted — against the live ceilings, so a default above the ceiling makes every
  registration revert. Step 06 checks this before sending.
- **08 is last and mandatory.** Steps 00–06 run with the deployer as owner/admin so
  configuration doesn't need a multisig round-trip per call. Until 08 runs, an EOA can raise
  the org ceilings and allowlist tokens over live user funds. Step 07 fails while that is
  still true.

## Running against a multisig owner

Steps 01, 05 and 06 detect that the signer is not the owner (or `PRICE_ADMIN_ROLE` holder)
and write the calldata to `TimelockTxs/spend-module/<Network>-<step>.json` instead of
sending. Submit that batch, then run 07 to verify.

For the provider upgrade path, `VALIDATE_ONLY=1` deploys and validates a new implementation
and prints the `upgradeToAndCall` calldata without switching:

```bash
VALIDATE_ONLY=1 npx hardhat run scripts/spend-module/upgradeSolidPriceProvider.js --network fuse
```

## What step 07 checks

Wiring, pricing, the allowlist, caps, and ownership — plus two things no single contract
enforces:

- **The spender cannot widen its own bounds.** `requiresAuth` on `SolidCashModule` is uniform
  across `spend`, the guardian functions and every `set*`, so the documented role separation
  lives entirely in the authority's capability table. 07 asserts `SPENDER_ROLE` cannot call
  `setOrgCaps`, `allowSpendToken`, `setPriceProvider`, `setDefaultLimits` or `setDustFloor`,
  and that no role can call the inherited `transferOwnership` or `setAuthority`.
- **`lens.availableToSpend` does not revert.** That single `eth_call` is the whole authorize
  path, and its per-token `balanceOf` / `priceUsd` reads are unguarded — one bad allowlisted
  asset declines every user's card, not just the holder's. 07 calls it against a codeless
  address (the counterfactual-Safe case) and reports its gas.

It exits non-zero on any failure, so it can gate a release.

## After deploying

The module is inert until a Safe opts in. Enabling is an owner-signed batch, since Safe 1.4.1
has no module-setup callback:

1. `Safe.enableModule(SolidCashModule)`
2. `SolidCashModule.registerSafe(dailyLimitUsd, monthlyLimitUsd, timezoneOffset)` — called
   **by the Safe**, passing 0 for either limit to take the org default.

The backend needs `SolidCashLens` (authorize reads) and `SolidCashModule` (settlement). One
caveat for the integration: `SpendAvailability` carries both `limitRemainingUsd`, which is
clamped to the live org ceilings, and `limit`, which is raw per-Safe state and is not.
Compute headroom from `limitRemainingUsd`.
