# Deploying the AI API billing module

Step-by-step runbook for `SolidUsageBillingModule` on **Base (chain 8453)**, for
QA and for production, and for wiring the backend to it afterwards.

Read [README.md](./README.md) first for what the contract does. This file is
only how to get it live. It follows the rewards v3 runbook
([../solid-rewards/DEPLOYMENT.md](../solid-rewards/DEPLOYMENT.md)) step for
step where the two are the same, and says so rather than repeating it.

Work through steps 1–11 in order. Everything after them is reference.

> **Two values are immutable once the constructor runs:** `revenueTreasury`
> (where every charge goes) and `minPeriod` (the shortest billing period any
> user can ever sign). Neither has a setter. A wrong value is a redeploy and a
> re-signature from every user who subscribed in between. Step 5 exists to stop
> that.

**Do QA first, all the way to step 11, before you start prod.**

---

## Step 1 — Toolchain and submodules

Exactly rewards steps 1 and 2: Foundry 1.5.x on your PATH, then

```bash
git clone git@github.com:Solid-Money/boring-vault.git && cd boring-vault
git checkout qa
git submodule update --init --depth 1 lib/solmate lib/openzeppelin-contracts lib/forge-std
```

The compiler profile in `foundry.toml` is **solc 0.8.21, `evm_version =
london`, optimizer 200 runs**. Keep it: Base would accept a newer EVM, but the
module is built and tested with this profile, and the rewards contracts share
it.

---

## Step 2 — Run the tests

```bash
forge test --match-path "test/Solid*.t.sol" \
  --skip "script/*" \
  --skip "src/fuse/FastWithdrawManager/*" --skip "src/fuse/CardManager/*" \
  --skip "test/*CardDeposit*" --skip "test/*FastWithdraw*"
```

Expect **121 passing, 0 failed** across four suites, of which **41** are
`SolidUsageBillingModule`. No fork is needed.

> The two extra `src/fuse/*` skips are for checkouts without `node_modules`:
> `FastWithdrawManager` and `CardDepositManager` import LayerZero from
> `node_modules/`, and forge compiles the whole project before it picks tests.
> With `npm ci` run, the rewards runbook's single `--skip "script/*"` works too.

---

## Step 3 — Decide the numbers

Two of these are immutable and one is a live throttle. Agree them before step
4, not during it.

| value | what it is | recommended | notes |
| --- | --- | --- | --- |
| `AI_BILLING_MIN_PERIOD` | shortest period a mandate's cap may apply to, seconds. **Immutable** | `86400` (24 hours) | The backend signs **24 hours** (`AI_API_BILLING_PERIOD_SECONDS`) and charges every few dollars inside it; the cap is what all of a period's charges add up to. A floor of a day makes "up to $X a day" the contract's promise rather than the backend's: no mandate can apply its cap over a shorter window. Must be ≥ 86400: the module refuses less. |
| `AI_BILLING_MAX_CHARGE_AMOUNT` | org ceiling on one charge, **micro-USD**. Changeable, binds existing mandates | `1000000000` ($1,000) | Also caps the mandate a user can sign: the backend refuses key limits adding up past it. Keep it ≥ *keys per user × highest monthly limit* from the portal (Config → AI API) or users hit "Your keys' monthly limits can add up to $X at most". |
| `AI_BILLING_TOKENS` | billing tokens, comma-separated, **in draw order** | USDC on Base | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. Changeable later with `setBillingTokens` (step 9). |
| `AI_BILLING_RATE_PROVIDERS` | one per token, same order | `0x0000000000000000000000000000000000000000` | Zero means a dollar at par. A share token names its accountant. |

> **soUSD is not on Base yet.** The USD vault's share exists on Ethereum and
> Fuse only — the address it has on Ethereum holds an unrelated contract on Base
> (the cash module's Chainlink adapter). Deploy with USDC alone and add soUSD
> with step 9 once its share and an accountant (or any `getRate()` provider in
> micro-USD per whole share) exist on Base. No user signs again for it.

---

## Step 4 — Fill in `.env`

```bash
cp sample.env .env   # once
```

Add these. `BASE_RPC_URL` is what the `base` alias in `foundry.toml` resolves to.

| variable | QA | production |
| --- | --- | --- |
| `BASE_RPC_URL` | a Base RPC, e.g. `https://mainnet.base.org` | same |
| `PRIVATE_KEY` | deployer EOA with a little ETH on Base | same; holds no rights after the constructor |
| `AI_BILLING_OWNER` | `0x26F9A59F0F0e92e8a8d6f835d57657a3a3b51103` (QA owner EOA) | `0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3` (Base Safe, 3 of 4) |
| `AI_BILLING_ALLOW_EOA_OWNER` | `true` (the owner above is an EOA) | unset: the script refuses an owner that isn't a Safe needing 2+ signatures |
| `AI_BILLING_TREASURY` | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` |
| `AI_BILLING_MAX_CHARGE_AMOUNT` | `1000000000` | `1000000000` |
| `AI_BILLING_MIN_PERIOD` | `86400` | `86400` |
| `AI_BILLING_TOKENS` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `AI_BILLING_RATE_PROVIDERS` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` |

- **The owner on prod is the Base Safe**, not the Fuse one. The Fuse owner
  `0xBA30…1F29` has no code on Base, so pointing the module at it would make
  it unownable. `0x5Eb1…5Eff3` is the Safe that already owns the Base card
  spend module and the Base `RolesAuthority`.
- **The treasury is the revenue wallet**, the same address the rewards module
  pays on Fuse. It is an EOA, so it receives on Base as it is. Re-derive it from
  helm (`REVENUE_WALLET_ADDRESS`) if time has passed.
- QA and prod deliberately share the treasury and the token: what differs
  between them is who owns the module and who may bill through it.

---

## Step 5 — Pre-flight: check every constructor argument against the chain

```bash
source .env

# USDC on Base: 6 decimals. Amounts here are micro-USD, so USDC at par needs no conversion.
cast call $AI_BILLING_TOKENS "decimals()(uint8)" --rpc-url base   # 6
cast call $AI_BILLING_TOKENS "symbol()(string)"  --rpc-url base   # USDC

# The owner. Prod: a Safe (code, and 3 owners of 4 required).
cast code $AI_BILLING_OWNER --rpc-url base | head -c 20           # prod: non-empty. QA: 0x (an EOA)
cast call $AI_BILLING_OWNER "getThreshold()(uint256)" --rpc-url base   # prod only: 3

# The treasury: any address you control. This read only catches a typo.
cast call $AI_BILLING_TOKENS "balanceOf(address)(uint256)" $AI_BILLING_TREASURY --rpc-url base

# Base, and nothing else.
cast chain-id --rpc-url base                                       # 8453
```

The script refuses to run on any chain but 8453, so a `BASE_RPC_URL` pointing
at Fuse or a testnet fails at simulation, not after a broadcast.

---

## Step 6 — Deploy

Dry-run first. Without `--broadcast` it prints the address and sends nothing:

```bash
forge script script/DeploySolidUsageBilling.s.sol --rpc-url base \
  --skip "src/fuse/FastWithdrawManager/*" --skip "src/fuse/CardManager/*" --skip "test/**"
```

Then for real:

```bash
forge script script/DeploySolidUsageBilling.s.sol --rpc-url base \
  --skip "src/fuse/FastWithdrawManager/*" --skip "src/fuse/CardManager/*" --skip "test/**" \
  --private-key $PRIVATE_KEY --broadcast --slow
```

**Record the address it logs.** About 3.3M gas — fractions of a cent on Base.
(The Fuse `mixHash` receipt error from the rewards runbook does not happen on
Base.)

---

## Step 7 — Check what landed

```bash
export MODULE=0x…    # from step 6

cast call $MODULE "revenueTreasury()(address)" --rpc-url base   # == $AI_BILLING_TREASURY
cast call $MODULE "minPeriod()(uint64)"         --rpc-url base   # == $AI_BILLING_MIN_PERIOD
cast call $MODULE "maxChargeAmount()(uint128)"  --rpc-url base   # == $AI_BILLING_MAX_CHARGE_AMOUNT
cast call $MODULE "owner()(address)"            --rpc-url base   # == $AI_BILLING_OWNER
cast call $MODULE "authority()(address)"        --rpc-url base   # 0x0, for now
cast call $MODULE "billingTokensList()((address,address,uint8)[])" --rpc-url base
# [(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x0000000000000000000000000000000000000000, 6)]
```

`revenueTreasury` and `minPeriod` are the immutable pair. If either is wrong,
stop and redeploy before anyone subscribes.

### Verify the source (optional, worth doing)

So the owner Safe's signers can read what they approve:

```bash
forge verify-contract $MODULE \
  src/solid-billing/SolidUsageBillingModule.sol:SolidUsageBillingModule \
  --chain base --verifier blockscout --verifier-url https://base.blockscout.com/api/ \
  --constructor-args $(cast abi-encode \
      "constructor(address,address,uint128,uint64,address[],address[])" \
      $AI_BILLING_OWNER $AI_BILLING_TREASURY $AI_BILLING_MAX_CHARGE_AMOUNT $AI_BILLING_MIN_PERIOD \
      "[$AI_BILLING_TOKENS]" "[$AI_BILLING_RATE_PROVIDERS]")
```

(For Basescan instead: `--verifier etherscan --etherscan-api-key $BASESCAN_KEY`.)

---

## Step 8 — Grant the biller role

Nothing bills until this is done. Until then `charge` is owner-only.

### 8a. Find the biller

**The backend's ERC-4337 smart account on chain 8453** — not the EOA that signs
for it, and never a user Safe. `AiApiBillingService` submits through
`AAOperationsService.execute(8453, …)`, so at the module `msg.sender` is that
account.

Get it from `GET /admin/v1/wallets/status` (the Wallets page in the admin
dashboard): **"Direct Deposit AA Wallet"** on prod, **"Direct Deposit Smart
Account"** on QA, Base row. The address is derived from
`SMART_ACCOUNT_SIGNER_KEY`, so **QA and prod differ** — never copy one into the
other's grant.

| | biller |
| --- | --- |
| production | `0x54C11A6185907bC464fa6aCA0901Aea9DbDD08Fe` — the same account that bills tier fees on Fuse; it is already deployed on Base |
| QA | read it from the QA Wallets page |

### 8b. The authority

**Production** uses the Base `RolesAuthority` that already governs the Base
card spend module:

```bash
export AUTH=0x306D7a1c938A6fe5464b02982357d745E5464aa2
cast call $AUTH "owner()(address)" --rpc-url base   # must be 0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3
```

**QA** has no authority on Base yet. Deploy one, owned by the QA owner EOA:

```bash
forge create src/fuse/FuseRolesAuthority.sol:FuseRolesAuthority \
  --rpc-url base --private-key $PRIVATE_KEY --broadcast \
  --constructor-args $AI_BILLING_OWNER 0x0000000000000000000000000000000000000000
export AUTH=0x…   # the address it prints
```

(`FuseRolesAuthority` is a plain solmate `RolesAuthority`; the name is
historical. `--broadcast` is required in Foundry 1.x or nothing is sent.)

### 8c. Pick a free role number

Roles are numbers the authority holds, shared by everything it governs, so
granting one that is in use hands its holders `charge()` and hands the biller
theirs. **Read the authority's history; do not trust a list.**

```bash
# The block the authority was deployed in: the first one at which it has code.
lo=0; hi=$(cast block-number --rpc-url base)
while [ $((hi - lo)) -gt 1 ]; do
  mid=$(((lo + hi) / 2))
  if [ "$(cast code $AUTH --block $mid --rpc-url base)" = "0x" ]; then lo=$mid; else hi=$mid; fi
done
export FROM=$hi

cast logs --address $AUTH --from-block $FROM --rpc-url base \
  "UserRoleUpdated(address indexed,uint8 indexed,bool)"
cast logs --address $AUTH --from-block $FROM --rpc-url base \
  "RoleCapabilityUpdated(uint8 indexed,address indexed,bytes4 indexed,bool)"
# topics[2] of the first, topics[1] of the second, is the role number.
```

The binary search needs an RPC that serves historical state; a public endpoint
that does not will answer every `--block` with `0x`. If a provider caps the
`cast logs` range, page it with `--to-block`.

Take the lowest number that appears in neither list. On QA's fresh authority
that is **1**. Then confirm nothing holds `charge()` on this module yet:

```bash
cast call $AUTH "getRolesWithCapability(address,bytes4)(bytes32)" $MODULE 0x1e1d709a --rpc-url base
# 0x00…00
```

`0x1e1d709a` is `charge(address,bytes32,uint256)` — the same selector as on the
rewards module, which is why reading the role's history matters.

### 8d. Send the three transactions

```bash
set -u
export MODULE=0x…                          # from step 6
export AUTH=0x…                            # 8b
export BILLER=0x…                          # 8a
export BILLER_ROLE=…                       # 8c
export CHARGE_SELECTOR=0x1e1d709a
```

**QA (owner is an EOA).** With the QA key in a keystore
(`cast wallet import solid-qa --interactive`, once):

```bash
# 1 of 3 — point the module at the authority. Sent by the MODULE's owner.
cast send --account solid-qa "$MODULE" "setAuthority(address)" "$AUTH" --rpc-url base

# 2 of 3 — let the biller role call charge() on this module. Sent by the AUTHORITY's owner.
cast send --account solid-qa "$AUTH" "setRoleCapability(uint8,address,bytes4,bool)" \
  "$BILLER_ROLE" "$MODULE" "$CHARGE_SELECTOR" true --rpc-url base

# 3 of 3 — give the biller role to the backend's smart account.
cast send --account solid-qa "$AUTH" "setUserRole(address,uint8,bool)" \
  "$BILLER" "$BILLER_ROLE" true --rpc-url base
```

**Production (owner is the Base Safe).** Build the same three as calldata and
batch them in the Safe's Transaction Builder **on Base**, one multisend, so the
authority is never attached without the role:

```bash
cast calldata "setAuthority(address)" "$AUTH"                         # to: $MODULE
cast calldata "setRoleCapability(uint8,address,bytes4,bool)" \
  "$BILLER_ROLE" "$MODULE" "$CHARGE_SELECTOR" true                    # to: $AUTH
cast calldata "setUserRole(address,uint8,bool)" "$BILLER" "$BILLER_ROLE" true   # to: $AUTH
```

### 8e. Confirm

```bash
cast call "$AUTH" "doesUserHaveRole(address,uint8)(bool)" "$BILLER" "$BILLER_ROLE" --rpc-url base
cast call "$AUTH" "canCall(address,address,bytes4)(bool)" "$BILLER" "$MODULE" "$CHARGE_SELECTOR" --rpc-url base
cast call "$MODULE" "authority()(address)" --rpc-url base    # == $AUTH
# true, true, $AUTH
```

> Grant the biller **`charge` and nothing else**. Not `setBillingTokens`
> (`0x890bd077`) — that is the price list, and the biller must not be able to
> choose what a dollar of usage costs in tokens. Not `pause`,
> `setMaxChargeAmount`, `setSafePaused`, `setAuthority` or `transferOwnership`
> (which is `requiresAuth`, so a role holding it can take the contract).

---

## Step 9 — Adding a billing token (soUSD, and anything after it)

Owner-only, one call, no redeploy, and **no user signs again** — their mandate
is in dollars and still binds.

```bash
# The whole list, in draw order: USDC first, then soUSD.
export SOUSD_BASE=0x…            # the soUSD share on Base
export SOUSD_RATE_PROVIDER=0x…   # its accountant on Base: getRate() in micro-USD per whole share

# Pre-flight: the provider answers, in micro-USD, around 1.07e6 for soUSD.
cast call $SOUSD_RATE_PROVIDER "getRate()(uint256)" --rpc-url base
cast call $SOUSD_BASE "decimals()(uint8)" --rpc-url base

cast calldata "setBillingTokens(address[],address[])" \
  "[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,$SOUSD_BASE]" \
  "[0x0000000000000000000000000000000000000000,$SOUSD_RATE_PROVIDER]"
# → Transaction Builder on the owner Safe, to: $MODULE
```

The call refuses a token with no code, a duplicate, more than 8 tokens, and a
rate provider that has no code or answers zero — so a wrong address costs a
revert, not a user's charge. Reorder or remove tokens the same way: the list is
always replaced whole.

**Treat it like a price-feed change.** A rate provider that under-prices a
token makes the user pay more units of it than the dollars they owe; one that
over-prices it pays the treasury less than the dollars charged. The signers
should check `getRate()` against the share's real price before approving.

---

## Step 10 — Point the backend at it

`solid-backend`, accounts-service, `helm/values/{qa,prod}.yaml`:

```yaml
AI_API_BILLING_MODULE_ADDRESS: "0x…"   # $MODULE
```

- The AI API bills on **Base** (`AI_API_CHAIN_ID = 8453` in code): the Wallet
  balance it shows is `billableBalanceOf`, and charges go out through the
  backend smart account on 8453.
- Empty is a valid state, not an error. Creating a key then answers "billing
  is not set up yet" and nothing is charged, which is why the backend can ship
  before this runbook is done.
- The app needs nothing: it reads the module address, the chain and the period
  from the backend when it asks the user to sign.

Then in the portal (Config → AI API): check that keys per user × highest
monthly limit is at or below `maxChargeAmount` in dollars (step 3).

---

## Step 11 — Smoke test

On a QA user's Safe on Base, after they have created a key (which signs the
mandate):

```bash
export SAFE=0x…           # the user's Safe — the same address on Base as everywhere
export AMOUNT=1000000     # $1.00

cast call $MODULE "subscriptionOf(address)((bool,bool,uint128,uint64,uint64,uint64,uint64,uint64,uint128))" $SAFE --rpc-url base
cast call $MODULE "allowanceOf(address)(uint256,uint64)" $SAFE --rpc-url base  # left this period, when it ends
cast call $MODULE "billableBalanceOf(address)(uint256)" $SAFE --rpc-url base   # micro-USD
cast call $MODULE "canCharge(address,uint256)(bool,string)" $SAFE $AMOUNT --rpc-url base
cast call $MODULE "quote(address,uint256)((address,uint256,uint256)[],uint256)" $SAFE $AMOUNT --rpc-url base
```

`canCharge` is the whole diagnosis, in the same words as the rewards module so
one backend reads both: `not subscribed`, `module not enabled`, `too soon`
(this period's cap is used up — see `allowanceOf`), `exceeds mandate`,
`exceeds org ceiling`, `insufficient balance`, `zero amount`, `cancelled`,
`safe paused`, `module paused`.

Then use the key until it has billed a few dollars. The backend's billing pass
runs every minute and charges once unpaid usage reaches $5 (and whatever is
left when a UTC day closes); `POST /accounts/v1/ai-api/billing/retry` as the
user retries a waiting charge. Check:

- the `Charged` and `Drawn` events on the module,
- the USDC arriving at the treasury,
- the "AI API" row in the user's Activity with the per-key split,
- the charge on the user's page in the admin dashboard (AI API → user).

Only then repeat on production. Leave `AI_API_BILLING_MODULE_ADDRESS` empty in
prod until QA has completed a real charge.

---
---

# Reference

## A. Who owns what

`solmate/Auth`, constructed as `Auth(OWNER, Authority(0))`. `requiresAuth`
passes for the owner, or for whoever an attached authority allows.

| The owner can | The owner cannot |
| --- | --- |
| `setBillingTokens` — which tokens, what order, priced how | redirect the money (`revenueTreasury` is immutable) |
| `setMaxChargeAmount` (binds existing mandates too) | charge more dollars than a user's own mandate |
| `setSafePaused` (one Safe) | take more in one period than the user's cap, however many charges it is split into, or shorten a period below `minPeriod` |
| `pause` / `unpause` | charge a Safe that has not enabled the module |
| `charge` (the owner passes every `requiresAuth`) | re-use a `billingId` |
| `setAuthority`, `transferOwnership` | |

Permissionless: `subscribe`, `cancel`, `resume` (the caller is the Safe, so a
Safe only ever speaks for itself) and every view.

## B. Kill switches, in increasing order of severity

| Situation | Action | Effect |
| --- | --- | --- |
| Something looks wrong, cause unknown | Portal → Config → AI API → off | Keys stop and no new ones are made. Nothing on-chain changes |
| Billing is misbehaving | Clear `AI_API_BILLING_MODULE_ADDRESS`, redeploy | The backend stops charging; usage waits in open charges |
| One Safe is being charged wrongly | `setSafePaused(safe, true)` | That Safe only. The backend pauses the user's AI API as an admin pause |
| A token is mispriced | `setBillingTokens` without it | It stops being drawn from at once |
| Charges must stop chain-wide, now | `pause()` | Every charge reverts; the backend keeps them open and pauses nobody |
| Mandates are too large | `setMaxChargeAmount(lower)` | Binds existing mandates — a live throttle |

The user's own switches are `cancel()` here and `disableModule` on their Safe;
the second needs no app and no us.

## C. Selectors

| | |
| --- | --- |
| `charge(address,bytes32,uint256)` | `0x1e1d709a` |
| `setBillingTokens(address[],address[])` | `0x890bd077` |
| `setMaxChargeAmount(uint128)` | `0x5f4b9162` |
| `setSafePaused(address,bool)` | `0x75fcbf32` |
| `pause()` | `0x8456cb59` |
| `subscribe(uint128,uint64)` | `0x8e4dc57a` |

Re-derive any of them with `cast sig "<signature>"`.

## D. Known addresses (Base, 8453)

Checksummed; `cast` rejects a wrongly-cased address, so copy rather than retype.

| | QA | production |
| --- | --- | --- |
| owner | `0x26F9A59F0F0e92e8a8d6f835d57657a3a3b51103` (EOA) | `0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3` (Safe, 3 of 4) |
| `RolesAuthority` | deploy in step 8b | `0x306D7a1c938A6fe5464b02982357d745E5464aa2` |
| biller (backend smart account) | from the QA Wallets page | `0x54C11A6185907bC464fa6aCA0901Aea9DbDD08Fe` |
| revenue treasury | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `SolidUsageBillingModule` | — | — |

Fill the last row in once deployed. Re-read the rest from the chain if time has
passed:

```bash
cast call $MODULE "owner()(address)" --rpc-url base
cast call $MODULE "authority()(address)" --rpc-url base
cast call $AUTH "owner()(address)" --rpc-url base
```

## E. Order of merging across the repos

```
boring-vault  →  solid-backend  →  solid-management-portal  →  solid-ui
```

- **boring-vault** first: the module address in step 10 comes from it.
- **solid-backend** next. Safe to deploy immediately: with the address empty,
  creating a key answers "not set up yet" and nothing is billed.
- **solid-management-portal**: the per-tier AI cashback and the AI API page
  need the new backend endpoints.
- **solid-ui** last: it asks the user to sign on Base only once the backend
  names a module.
