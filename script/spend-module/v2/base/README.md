# SolidCashModuleV2 on Base — EURC spending

A **second instance** of the same module, on Base, **denominated in dollars exactly as Fuse is**.
EURC is an ordinary spendable asset priced at about 1.08, the same way soUSD is priced at about
1.07. Fuse is untouched and its cohort keeps running.

Plan and decision record: `~/.claude/plans/wirex-cash-phase4-multicurrency.md`.

| File | Purpose |
| --- | --- |
| `SpendModuleV2BaseConfig.sol` | Base addresses, EURC risk parameters, the v1 sentinel. Inherits the Fuse config for its helpers only. |
| `DeployChainlinkAdapterBase.s.sol` | **Step 1.** The price adapter, and EURC's quote. |
| `DeploySpendModuleV2Base.s.sol` | **Step 2.** Authority, provider, both halves, liquidator, lens, configuration, handover. |

Sealing reuses the Fuse `SealSettersV2.s.sol` unchanged: it resolves the core from the per-network
record, which on Base is `deployments/addresses/Base/SpendModuleV2.json`.

## Environment

**Put these in `.env` at the repo root, not in `export` lines.** Foundry loads it automatically, so
`vm.envOr` in the scripts reads them with no flags on the command line. `.env` is gitignored;
`sample.env` is the committed template and carries every key below with its rationale.

Several are already set for the Fuse deployment and are reused unchanged: `OWNER`, `SPENDER`,
`CREDIT_SPENDER`, `GUARDIAN`, `SETTLEMENT_TREASURY`, `BASE_RPC_URL`.

Required, no defaults, and the scripts refuse to run without them. **None were verified when these
scripts were written.** A wrong address in a price path fails silently rather than loudly, which is
why they are arguments rather than constants.

| Var | What it is |
| --- | --- |
| `EURC_ADDRESS` | EURC on Base |
| `EURC_USD_FEED` | Chainlink EURC/USD on Base |
| `SEQUENCER_UPTIME_FEED` | Chainlink's L2 sequencer uptime feed on Base |
| `SPENDER`, `GUARDIAN`, `LIQUIDATION_OPERATOR` | As on Fuse. The last two must each be their own key |

Optional: `OWNER`, `SETTLEMENT_TREASURY`, `CREDIT_SPENDER` (defaults to `SPENDER`), `AUTHORITY` (to
reuse an existing one), `SEQUENCER_GRACE_PERIOD` (default 1 hour), `EURC_USD_MAX_STALENESS`
(default 24 hours), `V1_MODULE_SENTINEL`, `SKIP_HANDOVER`.

## Running it

All commands below assume `.env` is populated.

**One exception, and it will bite you.** Foundry loads `.env` for `vm.env*` *inside* the scripts. It
does **not** populate your shell, so a `$VAR` written on the command line is expanded by the shell
before forge ever runs. The `--libraries` flags below are the only place that matters. Either paste
the addresses literally, or export them first:

```bash
set -a; source .env; set +a
```

A `$VAR` that expands to nothing there does not fail loudly. It links a library to the wrong
address, and the first symptom is a delegatecall reverting with no reason at `setParams`.

```bash
# Step 1 — the adapter
forge script script/spend-module/v2/base/DeployChainlinkAdapterBase.s.sol \
  --rpc-url base --broadcast -vvv

# Step 1b — OWNER multisig executes the printed setQuote calldata

# Step 2 — the instance
forge script script/spend-module/v2/base/DeploySpendModuleV2Base.s.sol \
  --rpc-url base --broadcast --slow -vvv \
  --libraries src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2:0x.. \
  --libraries src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib:0x.. \
  --libraries src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib:0x..

# Step 3 — OWNER multisig
forge script script/spend-module/v2/SealSettersV2.s.sol --rpc-url base --broadcast
```

The three libraries must be deployed **on Base** and linked explicitly, for the same reason as on
Fuse: letting `forge script` auto-deploy them makes the bytecode unreproducible between runs.

**Do not reuse the Fuse library addresses.** The same address holds different code on a different
chain, so linking Fuse addresses here produces a module that deploys cleanly and then reverts with
no reason the first time it calls into a library. Confirm each one after deploying:

```bash
cast call $SOLID_CASH_CONFIG_LIB "MAX_GRACE_FLOOR_HF()(uint64)" --rpc-url base   # 980000000000000000
cast call $SOLID_CASH_CONFIG_LIB "MAX_TARGET_LTV_BPS()(uint16)" --rpc-url base   # 9500
```

**The adapter is owned by the multisig from construction**, not handed over afterwards. Repointing a
feed is equivalent to setting a price, so there is deliberately no window in which a deployer EOA
holds that over a contract other systems are about to trust. The consequence is that step 1 cannot
configure its own quote unless the deployer is the owner, so it prints calldata instead. Step 2
refuses to proceed until that calldata has landed, because an unconfigured adapter leaves EURC
unpriceable and every check would fail after the gas was spent.

## Launch shape, and why

**Debit only.** No collateral, no credit, no soEUR. Not staging for its own sake: it keeps a first
deployment on a new chain to exactly two new things, a second instance and a real oracle adapter, so
a failure has one of two causes rather than six. Credit needs soEUR, which does not exist anywhere.

**EURC is `EXTERNAL_ADAPTER`, not `STABLE_ADAPTER`.** In dollars EURC floats. `STABLE_ADAPTER`
returns `min(peg, observed)` and would cap it at a dollar, understating it by the euro premium and
over-collecting on every euro purchase.

**Its band is deliberately loose**, 0.80–1.50 on the module against 0.85–1.45 on the provider. An
out-of-band price sets `fullyPriced` false, which freezes liquidation for the **whole position**
rather than discounting one asset, so a band tight enough to be a real sanity check would be a
recurring system-wide outage. `setTokenPaused` is the lever that actually answers a suspect feed.
The two bands are asserted strictly nested, because identical bands were a standing v1 finding.

**`ceilingGrowthPerSec` is zero and not negotiable.** The drifting ceiling only ratchets upward,
which models a monotonically appreciating share. An exchange rate is not one.

**EURC is not collateral and not tender.** Collateral is withheld because lending against an asset
whose dollar value moves with a currency puts FX into every borrower's health factor, which deserves
its own risk parameters rather than arriving as a side effect of making EURC spendable. Tender is
withheld because no debt can exist on a debit-only instance, so enabling it later stays a decision
rather than an inherited default.

**There is no v1 on Base**, but both the module and the lens reject a zero `v1Module`. A sentinel is
used — the burn address by default, recognisable in an explorer and provably nobody's contract. The
check is `ISafe(safe).isModuleEnabled(v1Module)`, so an address never enabled as a module answers
false forever. It costs one wasted external call per spend, which was judged cheaper than changing
audited constructors for a deployment-shaped problem.

**A fresh authority by default.** Base already has a `RolesAuthority` from the LBTC vault. Reusing it
would mean a role granted for a vault reaches a card module, so this deploys its own unless
`AUTHORITY` says otherwise.

## Backend, after step 3

None of this is reachable by a cardholder until:

- **EURC is added to `TOKEN_SETTLEMENT_CURRENCY`** in `cash.constants.ts`. Until it is, an unmapped
  asset counts as converting and the FX waiver never fires, so euro purchases funded from EURC are
  still charged 1%.
- **The chain is registered** in each user's `deployments` on `SafeSpendConfig`.
- **`CASH_SPEND_LENS_ADDRESS` for 8453** points at the lens this script records.
- **Routing exists.** Nothing yet chooses an instance per transaction, writes the instance onto the
  operation, or unions the two spending limits. That is the largest remaining piece and the only
  place the cross-instance invariants get enforced: one settlement id booked on exactly one
  instance, and reversals routed by the stored instance rather than by currency.

## Not done

- **A Base verifier.** The Fuse `SpendModuleV2Verifier` asserts the v1 cohort still prices and reads
  v1's record, neither of which exists here. Step 2 asserts its own wiring inline as it goes, but
  there is no standalone re-runnable check yet.
- **A fork rehearsal.** The Fuse deployment has `rehearse()`, which runs the whole sequence against
  live state in one fork. Worth adding before the real run.
