# Deploying rewards v3

Runbook for `SolidTierLock` and `SolidSubscriptionModule` on Fuse (chain 122),
and for turning the two upgrade routes on afterwards.

Read [README.md](./README.md) first for what the contracts do and why they are
shaped this way. This file is only how to get them live.

Three values are **immutable** once the constructor runs — the module's
`billingToken` and `revenueTreasury`, and the lock's share token. None of them
has a setter. A wrong value there is not a config fix, it is a redeploy and a
migration of everyone who subscribed in between. §2 exists to stop that.

---

## 0. Who owns what

Both contracts are `solmate/Auth`, constructed as `Auth(OWNER, Authority(0))`.
Neither is permissionless and neither is ownerless.

`requiresAuth` passes if the caller is `owner`, **or** if an attached
`Authority` says the caller may call that selector. Until an authority is
attached, the owner is the only address that can reach anything gated.

**Set `OWNER` to the Safe multisig, never to the deployer EOA.** The deployer
holds no rights at all once the constructor has run — ownership is an argument,
not `msg.sender`. On Fuse today `SolidCashModule` is owned by

```
0xbA308F2919Aa20FbD58fc7406451077FE32F1f29   (a Safe; also owns the authority below)
```

Use the same one unless there is a reason not to.

### What the owner can do

| `SolidTierLock` | `SolidSubscriptionModule` |
| --- | --- |
| `setLockDuration` (new locks only) | `setMaxChargeAmount` (binds existing mandates too) |
| `setMinLockShares` | `setSafePaused` (one Safe) |
| `pause` / `unpause` (new locks only) | `pause` / `unpause` |
| `rescue` (excess only) | `charge` (implicitly — the owner passes every `requiresAuth`) |
| `setAuthority`, `transferOwnership` | `setAuthority`, `transferOwnership` |

### What the owner cannot do

- **Take a locked position.** `rescue` subtracts `totalLockedShares` before it
  transfers, so only a stray donation is reachable. There is no value of any
  setter that reaches a user's lock.
- **Extend a lock in flight.** Each lock snapshots its own `unlocksAt`, so
  raising `lockDuration` applies to future locks only.
- **Block a withdrawal.** `pause` gates `lock`, never `withdraw`.
- **Redirect the money or change the asset.** `revenueTreasury` and
  `billingToken` are immutable.
- **Bill outside the user's mandate.** Amount, frequency and single-use
  `billingId` are all enforced against what the Safe itself authorised.
- **Bill a Safe that has not enabled the module.** The Safe enforces that, not
  us.

### What is permissionless

- `lock`, `withdraw`, and every view function.
- **`withdrawFor(account)`** — anyone may call it for anyone, and the shares go
  to `account`, never to the caller. That is what lets a keeper unlock matured
  positions without the user coming back.
- `subscribe` / `cancel` / `resume` — `msg.sender` is the Safe, so each Safe
  self-serves and can only ever speak for itself.

> **Do not grant `transferOwnership` to a role.** It is `requiresAuth`, not
> owner-only, so a role holding it can take the contract.

---

## 1. Toolchain

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # forge + cast
git clone git@github.com:Solid-Money/boring-vault.git && cd boring-vault
git submodule update --init --depth 1 lib/solmate lib/openzeppelin-contracts lib/forge-std
cp sample.env .env      # then fill it in — see §2
```

Only those three submodules are needed for these contracts; the rest of the
repo's `lib/` is large and unrelated.

The pinned toolchain is in `foundry.toml`: **solc 0.8.21, `evm_version = london`,
optimizer on at 200 runs.** London is deliberate and matters on Fuse — do not
raise it to `paris`/`shanghai` for this deployment.

Networks are already configured. `foundry.toml` maps `fuse` to `${FUSE_RPC_URL}`
and `hardhat.config.js` has the same endpoint under chainId 122, so `--rpc-url
fuse` works once `FUSE_RPC_URL` is set. **Hardhat is not used for this
deployment** — it is present for other work in the repo.

Run the tests before anything else:

```bash
forge test --match-path "test/Solid*.t.sol"     # 58 tests, no fork needed
```

If a full `forge build` fails, it is not you: `script/GigaDeployDecoderAndSanitizer.s.sol`
and `script/DeployDecodersAndSanitizersWithNoConstructorArgs.s.sol` import
`LombardBTCMinterDecoderAndSanitizer.sol` where the file on disk is
`LombardBtcMinterDecoderAndSanitizer.sol`. It builds on a case-insensitive
filesystem and breaks on Linux/CI. Unrelated to these contracts, and
`--match-path` steps around it.

### Two Fuse warnings you will see, and why neither is a problem

**`EIP-3855 is not supported ... Unsupported Chain IDs: 122`**

Forge checks the chain for PUSH0 (EIP-3855, a Shanghai opcode) and warns because
solc ≥ 0.8.20 emits it *by default*. This repo does not compile by default:
`foundry.toml` pins `evm_version = 'london'`, which predates PUSH0, so the
compiler cannot emit the opcode at all. The warning is about the chain, not
about this bytecode.

Verify rather than trust it — walk the deployed runtime code as opcodes,
skipping push immediates, and count `0x5f`:

```bash
cast code $MODULE --rpc-url fuse > /tmp/code.hex
# both contracts return 0
```

Both `SolidTierLock` and `SolidSubscriptionModule` contain **zero** PUSH0
opcodes when built with this profile. What would break is raising
`evm_version` — don't, for Fuse.

**`failed to fetch block ... missing field 'mixHash'`**

Fuse runs Nethermind with Aura (PoA), whose block headers carry `step` and
`signature` in place of `mixHash` and `nonce`. Alloy — the RPC layer under
forge/cast — expects a post-merge header and fails to deserialise. **This is a
receipt-fetching failure, not a transaction failure.** `forge script` has
already broadcast by the time it happens; the progress line showing `2/2 txes`
and `1/2 receipts` means both transactions are on chain and forge lost track of
one of them.

Do not re-run the script — you will deploy a second copy. Confirm on chain
instead:

```bash
cast code $LOCK --rpc-url fuse | head -c 20      # non-empty == deployed
cast call $LOCK "owner()(address)" --rpc-url fuse
```

`cast call`, `cast send` and `eth_getLogs` are unaffected; it is only the block
header parse. Re-running with `--resume` will hit the same wall, so treat the
on-chain read as the source of truth and record the addresses by hand.

---

## 2. Pre-flight — check every constructor argument against the chain

Do this before broadcasting, not after. `cast` reads from the same RPC the
deploy will use.

```bash
source .env

# The share token must be the soFUSE BoringVault, 18 decimals.
cast call $SOFUSE_VAULT "decimals()(uint8)"        --rpc-url fuse   # expect 18
cast call $SOFUSE_VAULT "symbol()(string)"         --rpc-url fuse

# The accountant must answer getRate() — a revert means the wrong address, and
# the lock's USD display is dead on arrival — AND it must price THIS vault.
# There are two soFUSE vaults on Fuse with identical names and symbols, so this
# second line is the one that catches the mistake that is actually easy to make.
cast call $SOFUSE_ACCOUNTANT "getRate()(uint256)"  --rpc-url fuse
cast call $SOFUSE_ACCOUNTANT "vault()(address)"    --rpc-url fuse   # == $SOFUSE_VAULT

# The billing asset must be 6-decimal USDC.e — and MAX_CHARGE_AMOUNT is in ITS
# base units, so this decides whether 500000000 means $500 or $500,000,000,000.
cast call $USDC "decimals()(uint8)"                --rpc-url fuse   # expect 6
cast call $USDC "symbol()(string)"                 --rpc-url fuse

# The treasury must be an address you control and can receive ERC-20 at. It is
# immutable: this is the last moment it can be corrected.
cast code $REVENUE_TREASURY --rpc-url fuse | head -c 20

# The owner must be the multisig, and it must exist on Fuse.
cast code $OWNER --rpc-url fuse | head -c 20       # non-empty for a Safe
```

**There are two soFUSE vaults on Fuse, each with its own accountant, and they
are not interchangeable.** Both are called "Solid Fuse" and both use the symbol
soFUSE, so the only way to tell them apart is `totalSupply()` — or, better,
`accountant.vault()`, which names the vault an accountant actually prices.

| | QA | Production |
| --- | --- | --- |
| soFUSE vault | `0xDA737B0C12a08D85C973F10f25459F07F2BB2882` | `0xb33c8F0b0816fd147FCF896C594a3ef408845e2C` |
| its accountant | `0xc864e169a1d40b957170E6c848BbcE49f28b361B` | `0xb29B5F760d38587f7F4C896C458B9EEB5CAd9C0C` |
| supply, at time of writing | ~5,025 | ~27,878,092 |

Pairing a vault with the other one's accountant compiles, deploys and returns a
plausible number — it is simply the wrong rate, and `lockedAssetsOf` will price
every position with it. **Always check `accountant.vault()` against the vault
you are passing**, which is what the pre-flight below does.

Common to both:

| | |
| --- | --- |
| USDC.e (6 dp) | `0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9` |
| Revenue wallet (prod) | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` |
| Owner Safe (prod) | `0xbA308F2919Aa20FbD58fc7406451077FE32F1f29` |
| `FuseRolesAuthority` (owned by that Safe) | `0x058Ca721E21492AD72979f9Fb52410F6da588800` |

Re-derive them from helm (`SOFUSE_VAULT_ADDRESS_FUSE`,
`SOFUSE_ACCOUNTANT_ADDRESS_FUSE`, `REVENUE_WALLET_ADDRESS`) rather than trusting
this table if time has passed.

---

## 3. Deploy

The deployer EOA needs native FUSE for gas and nothing else.

```bash
forge script script/DeploySolidRewards.s.sol \
  --rpc-url fuse \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --slow
```

Dry-run first by dropping `--broadcast`; it prints both addresses without
sending anything.

Record the two addresses it logs. Then verify the immutables actually landed —
the deployment is worthless if `revenueTreasury` is wrong and it is cheaper to
find out now:

```bash
LOCK=0x…    # SolidTierLock
MODULE=0x…  # SolidSubscriptionModule

cast call $MODULE "revenueTreasury()(address)" --rpc-url fuse   # == REVENUE_TREASURY
cast call $MODULE "billingToken()(address)"    --rpc-url fuse   # == USDC
cast call $MODULE "maxChargeAmount()(uint128)" --rpc-url fuse
cast call $MODULE "owner()(address)"           --rpc-url fuse   # == OWNER (the Safe)
cast call $LOCK   "lockToken()(address)"       --rpc-url fuse   # == SOFUSE_VAULT
cast call $LOCK   "lockDuration()(uint64)"     --rpc-url fuse   # == 31536000
cast call $LOCK   "owner()(address)"           --rpc-url fuse   # == OWNER
cast call $LOCK   "authority()(address)"       --rpc-url fuse   # == 0x0, for now
```

Source verification is optional on Fuse (`foundry.toml` ships every
`[etherscan]` entry commented out) but worth doing on Blockscout so the owner
multisig's signers can read what they are approving:

```bash
forge verify-contract $MODULE SolidSubscriptionModule \
  --chain-id 122 --verifier blockscout \
  --verifier-url https://explorer.fuse.io/api \
  --constructor-args $(cast abi-encode \
      "constructor(address,address,address,uint128)" \
      $OWNER $USDC $REVENUE_TREASURY $MAX_CHARGE_AMOUNT)
```

---

## 4. Grant the biller role

Nothing bills until this is done. Until then `charge` is owner-only, which is
the correct default: a mis-set env var cannot hand billing rights to an address
nobody meant.

### Which address gets the role

**The backend's ERC-4337 smart account** — not the EOA that signs, and never a
user Safe.

`AAOperationsService` logs it as `Smart Account ready on chain 122: 0x…`, but
**only once something has actually used chain 122** — the per-chain client is
lazily initialised on first use, so an environment that has never submitted a
UserOp on Fuse has never logged the line. That is why it shows up on prod and
not on QA.

Ask for it instead of waiting for it. The admins-service already exposes it:

```
GET /admin/v1/wallets/status        (admins-service, behind FirebaseAuthGuard)
```

Look for the entry named **"Direct Deposit Smart Account"** (QA) or **"Direct
Deposit AA Wallet"** (prod) — same account, different label. The handler calls
`getSmartAccountAddressAsync` across chains 1, 122, 137, 8453 and 42161, which
*forces* the lazy init, so hitting this endpoint both returns the address and
makes the boot log appear from then on. It is also the Wallets page in the admin
dashboard, if you would rather click than curl.

The address is derived from `SMART_ACCOUNT_SIGNER_KEY`, so **QA and prod have
different ones** — never copy prod's address into a QA role grant.

`TierBillingService` submits through `aaOperations.execute(...)`, so at the
module `msg.sender` is that smart account. The EOA only signs the UserOperation
and never appears as the caller — grant the role to it and every charge reverts
on `requiresAuth`. This is the same gate `CASH_SWEEP_USE_AA` documents in helm
for `SolidCashModule.spend`, for exactly the same reason.

A user Safe is wrong for a different reason: the biller chooses *which* Safe is
charged, so a Safe holding the role could charge every other subscriber. A
Safe's authority over its own billing is its mandate, set by `subscribe`, and
nothing more.

### Role id

Reuse the live `FuseRolesAuthority` at `0x058Ca721E21492AD72979f9Fb52410F6da588800`
— same owner, already operated. Roles **1, 2 and 3 are taken** on it (cash
module and card manager). **Use role 4** for `BILLER_ROLE`. Roles are plain
`uint8`s held by the authority, not constants in these contracts, so nothing in
the code needs to agree with the number — but confirm it is still free before
you use it:

```bash
AUTH=0x058Ca721E21492AD72979f9Fb52410F6da588800
cast call $AUTH "getRolesWithCapability(address,bytes4)(bytes32)" \
  $MODULE 0x1e1d709a --rpc-url fuse     # 0x00…00 = nothing holds charge() yet
```

### The three transactions

All sent **by whoever owns the contracts** (see §0), in this order. `charge` is
`0x1e1d709a`.

| # | to | call |
| --- | --- | --- |
| 1 | `$MODULE` | `setAuthority($AUTH)` |
| 2 | `$AUTH` | `setRoleCapability(4, $MODULE, 0x1e1d709a, true)` |
| 3 | `$AUTH` | `setUserRole($BILLER_ACCOUNT, 4, true)` |

1 must land before 3 means anything — a role granted on an authority the module
does not consult does nothing.

**The backend needs no role on `SolidTierLock`.** Everything it calls is
permissionless: `lockedSharesOf`, `lockedAssetsOf`, `maturedSharesOf`,
`nextUnlockOf`, `getLocks` and `lockDuration` are views, and `withdrawFor` —
the unlock cron's only write — is deliberately callable by anyone because the
shares can only ever go to the account that locked them. The lock's other
`requiresAuth` functions (`setLockDuration`, `setMinLockShares`, `pause`,
`rescue`) are owner operations, not backend ones.

The one thing that *does* need a role on the lock is the zap — see §4a. If you
are not deploying the zap, leave the lock's `authority()` at `0x0`, which keeps
those owner functions owner-only and is the tighter setting.

**Note on `$AUTH`:** the authority is a separate contract with its own owner.
`setAuthority` (1 and 2) is sent by the owner of *your* contracts;
`setRoleCapability` and `setUserRole` (3 and 4) are sent by the owner of the
**authority**. If you deployed with an owner that does not own
`0x058Ca721…588800` — which is the prod Safe — you cannot use that authority
without the Safe signing for you. Deploy your own instead:

```bash
forge create src/fuse/FuseRolesAuthority.sol:FuseRolesAuthority \
  --rpc-url fuse --private-key $PRIVATE_KEY \
  --constructor-args $OWNER 0x0000000000000000000000000000000000000000
```

Calldata for the three:

```bash
set -u                       # see the warning below — do this first
MODULE=0x…                   # SolidSubscriptionModule, from §3
AUTH=0x…                     # the RolesAuthority your owner controls
BILLER_ACCOUNT=0x…           # the backend smart account — see above

cast calldata "setAuthority(address)" "$AUTH"
cast calldata "setRoleCapability(uint8,address,bytes4,bool)" 4 "$MODULE" 0x1e1d709a true
cast calldata "setUserRole(address,uint8,bool)" "$BILLER_ACCOUNT" 4 true
```

> **`encode length mismatch: expected N types, got N-1` means a shell variable
> was empty, not that the signature is wrong.** An unset `$ROLE` expands to
> nothing and `cast` simply sees one argument fewer — `expected 4 types, got 3`
> on `setRoleCapability`, `expected 3 types, got 2` on `setUserRole`. The role
> id is written as the literal `4` above for that reason; `set -u` makes the
> shell fail loudly on the rest, and quoting every `"$VAR"` stops an empty one
> from vanishing silently.

**From a Safe owner** (production): open the Safe at `$OWNER`, use **Transaction
Builder**, and paste each target address with its hex into the custom-data field
(value 0). Batch all four into a single multisend so the window where the
authority is attached but the role is not never exists. Collect signatures and
execute.

**From an EOA owner** (QA, where `OWNER` is an EOA — no Safe involved at all):

Keep the key off the command line — an argument is visible in `ps`, in your
shell history, and in anything you paste. `cast` has `-i/--interactive` for
exactly this: it prompts for the key and echoes nothing.

```bash
cast send -i "$MODULE" "setAuthority(address)" "$AUTH" --rpc-url fuse
cast send -i "$AUTH" "setRoleCapability(uint8,address,bytes4,bool)" 4 "$MODULE" 0x1e1d709a true \
  --rpc-url fuse
cast send -i "$AUTH" "setUserRole(address,uint8,bool)" "$BILLER_ACCOUNT" 4 true \
  --rpc-url fuse
```

Better for more than one transaction: import the key once into a keystore and
name it, so nothing is prompted, pasted or held in the environment at all.

```bash
cast wallet import solid-qa --interactive     # once; asks for the key and a password
cast send --account solid-qa "$MODULE" "setAuthority(address)" "$AUTH" --rpc-url fuse
```

`--private-key "$PRIVATE_KEY"` works too and is what most examples show. Note
that `cast` has **no environment fallback for the raw key** — unlike `--account`
(`ETH_KEYSTORE_ACCOUNT`) and `--rpc-url` (`ETH_RPC_URL`), omitting
`--private-key` does not make it read `$PRIVATE_KEY`. And do not reach for a
bare `read -rs PRIVATE_KEY`: with `-s` and no prompt string it echoes nothing
and prints nothing, so a terminal waiting for input is indistinguishable from
one that has hung. If you want that shape, give it a prompt:
`read -rsp 'key: ' PRIVATE_KEY; echo`.

Confirm:

```bash
cast call "$AUTH" "doesUserHaveRole(address,uint8)(bool)" "$BILLER_ACCOUNT" 4 --rpc-url fuse
cast call "$AUTH" "canCall(address,address,bytes4)(bool)" "$BILLER_ACCOUNT" "$MODULE" 0x1e1d709a \
  --rpc-url fuse
# both true
```

Do **not** grant the role `pause`, `setMaxChargeAmount`, `setSafePaused`,
`rescue`, `setAuthority` or `transferOwnership`. The backend needs exactly one
selector.

---

## 4a. Deploy the zap, and grant it `lockFor`

Optional, and only for the one-press upgrade: without it a user pays a tier's
lock by depositing into Savings first and coming back once the shares have
landed, which works and is two signatures.

### Why it exists

A Safe can already batch "deposit" and "lock" into one user operation. What it
cannot do is read the shares the deposit minted before calling `lock` — the
amount has to be written into the calldata when the batch is signed, and it
depends on the vault's rate at the moment the batch executes. Quote it high and
the lock reverts on a balance that never arrived; quote it low and the user
locks under the tier threshold, commits their FUSE for a year and gets nothing
for it. `SolidTierLockZap` sits between the two calls and reads the real number.

It is **not** a custody hop. The user's own Safe calls it, it holds nothing
between calls, and it credits the lock to `msg.sender` — so the position is the
user's, returnable only to the user, exactly as a direct `lock` would be.

### Deploy

```bash
export TIER_LOCK=$LOCK
export SOFUSE_TELLER=0x…   # the Teller that mints soFUSE — NOT the vault

forge script script/DeploySolidTierLockZap.s.sol \
  --rpc-url fuse --private-key $PRIVATE_KEY --broadcast --slow
```

The constructor refuses a Teller whose `vault()` is not the share the lock
escrows, so a zap wired to the wrong Teller fails here rather than stranding the
first user's deposit in the periphery. Check it landed anyway:

```bash
ZAP=0x…

cast call $ZAP "lock()(address)"       --rpc-url fuse   # == $LOCK
cast call $ZAP "teller()(address)"     --rpc-url fuse   # == $SOFUSE_TELLER
cast call $ZAP "shareToken()(address)" --rpc-url fuse   # == SOFUSE_VAULT
cast call $ZAP "vault()(address)"      --rpc-url fuse   # == SOFUSE_VAULT, same address
```

### One more thing to check on the Teller

An atomic deposit-and-lock only works while the Teller's share lock period is
zero — a non-zero one makes the shares untransferable for that long, and the
zap's `lockFor` in the same transaction would revert.

```bash
cast call $SOFUSE_TELLER "shareLockPeriod()(uint64)" --rpc-url fuse   # must be 0
```

It is 0 on both QA and prod today. If it is ever set non-zero, turn the zap off
(unset the backend's address) rather than leaving users a button that reverts.

### Grant the role

Three transactions, sent by **whoever owns the lock and the authority** (see
§0). `lockFor` is `0x3d96e276`. Roles 1–4 are taken (cash module, card manager,
biller), so **use role 5**; confirm it is free first:

```bash
AUTH=0x058Ca721E21492AD72979f9Fb52410F6da588800
cast call $AUTH "getRolesWithCapability(address,bytes4)(bytes32)" \
  $LOCK 0x3d96e276 --rpc-url fuse     # 0x00…00 = nothing holds lockFor() yet
```

| # | to | call |
| --- | --- | --- |
| 1 | `$LOCK` | `setAuthority($AUTH)` |
| 2 | `$AUTH` | `setRoleCapability(5, $LOCK, 0x3d96e276, true)` |
| 3 | `$AUTH` | `setUserRole($ZAP, 5, true)` |

Transaction 1 is the one to think about: until now the lock has had no
authority, which made `setLockDuration`, `setMinLockShares`, `pause` and
`rescue` owner-only. Attaching an authority does not change that by itself —
they stay owner-only until someone grants a role for them — but it is the
moment they *become* grantable. Grant role 5 the `lockFor` selector and nothing
else.

Confirm:

```bash
cast call "$AUTH" "doesUserHaveRole(address,uint8)(bool)" "$ZAP" 5 --rpc-url fuse
cast call "$AUTH" "canCall(address,address,bytes4)(bool)" "$ZAP" "$LOCK" 0x3d96e276 \
  --rpc-url fuse
# both true
```

### Turning it off

`setUserRole($ZAP, 5, false)` stops new zaps immediately and touches no position
already taken. Unsetting the backend's `TIER_LOCK_ZAP_ADDRESS` is the softer
version: the app stops offering the one-press route and falls back to deposit-
then-lock, with no on-chain transaction at all.

---

## 5. Backend configuration

`solid-backend`, `accounts-service`. Five env vars, already present and empty in
`helm/values/{qa,prod}.yaml` and `.env.example`:

```yaml
TIER_LOCK_ADDRESS: "0x…"                  # $LOCK
TIER_LOCK_ZAP_ADDRESS: "0x…"              # $ZAP — empty until §4a is done
TIER_SUBSCRIPTION_MODULE_ADDRESS: "0x…"   # $MODULE
TIER_BILLING_TOKEN_ADDRESS: "0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9"
TIER_MEMBERSHIP_FUSE_RPC_URL: "https://rpc.fuse.io"
```

`TIER_LOCK_ZAP_ADDRESS` is the app's switch for the one-press upgrade. Empty
means the app asks the user to deposit into Savings first and come back, which
is the behaviour before §4a existed. Set it only once the role grant is
confirmed — an address set without the role gives users a button that reverts.

`TIER_BILLING_TOKEN_ADDRESS` **must equal the module's immutable
`billingToken`**. The module can only ever move that one token, so a mismatch
means every balance check runs against an asset the charge will not touch:
`canCharge` says yes and the charge reverts.

An empty address is not an error — the tier resolver reads it as "this route
does not exist yet" and falls back to points and staked FUSE, which is exactly
v2's behaviour. That is why the backend can ship before the contracts exist.

The **app-config switches** live in Mongo, not in env, and are edited from the
admin portal (`/rewards-config` → "Tier Membership (v3)"). All default to the v2
behaviour:

| key | default | |
| --- | --- | --- |
| `tier_membership.points_unlock_enabled` | `true` | v2's route; turn off when v3 replaces it |
| `tier_membership.lock.enabled` | `false` | the FUSE-lock route |
| `tier_membership.lock.duration_days` | `365` | must match the contract's `lockDuration` |
| `tier_membership.subscription.enabled` | `false` | the annual-fee route |
| `tier_membership.subscription.prime_annual_usd` | `199` | |
| `tier_membership.subscription.ultra_annual_usd` | `0` | **0 = not purchasable for cash.** Ultra is held by locking FUSE |
| `tier_membership.subscription.grace_days` | `7` | |
| `tier_membership.subscription.renewal_notice_days` | `7` | |

`lock.duration_days` is display copy only — the contract's `lockDuration` is
what actually binds. Keep them equal or the app will promise a term it does not
set.

### What the contracts do *not* decide

Two thresholds people expect to find in the contracts and will not:

- **`MIN_LOCK_SHARES` is a dust floor, not a tier price.** `SolidTierLock` has
  no idea what a tier is. The tier comes from the backend reading
  `lockedAssetsOf` and comparing it against `fuse_staking.tier2.amount` (50,000
  FUSE → Prime) and `fuse_staking.tier3.amount` (400,000 FUSE → Ultra).
  Locking the minimum buys a lock, and no tier at all.
- **`MAX_CHARGE_AMOUNT` is a ceiling, not a price.** The annual fee is
  `tier_membership.subscription.*_annual_usd`. The contract's ceiling only caps
  how large any single charge may be, and binds existing mandates when lowered.

So the two config values and the two constructor arguments have to agree with
each other by hand: a `MAX_CHARGE_AMOUNT` below the configured annual fee makes
every charge revert on `ExceedsOrgCeiling`, and thresholds changed in config do
not need the contracts touched at all.

### Funding an annual subscription

The fee is `billingToken`, immutable, which for this deployment is **USDC.e on
Fuse** (`0xc6Bc4077…e7f9`). It is charged out of the Safe's Fuse balance, so
that is the one balance that has to exist.

Know what the app does *not* do for that today: its two direct-deposit
destinations are `PROTOCOL`, which mints soUSD/soETH/soFUSE rather than leaving
a spendable stablecoin, and `RAIN_CARD`, which delivers USDC on **Base**.
Neither produces USDC.e on Fuse. The deposit-address screen lists Ethereum,
Polygon, Base, Arbitrum, BSC and Fuse, but it shows the user's own Safe address
— it is a receive address, not a bridge, so USDC sent on Base stays on Base.

The working path is to pick **Fuse** on that screen and receive USDC.e directly.
Anything else needs a bridge the app does not currently run for this purpose.

The UI needs no configuration: it reads all four addresses and the chain id from
the backend's membership state, so there is one place to get this wrong instead
of three.

---

## 6. Order of merging and rolling out

The repos depend on each other in one direction only, so:

```
boring-vault #8  →  solid-backend #1814  →  solid-management-portal #60  →  solid-ui #2523
```

- **boring-vault** first. Nothing builds against it, but the addresses in step 5
  come from it.
- **solid-backend** next. It serves the addresses and the membership state
  everything else reads. Safe to merge and deploy immediately — with the
  addresses empty and both switches off, behaviour is identical to today.
- **solid-management-portal** third. It `PATCH`es `/rewards-config/tier-membership`,
  an endpoint that only exists on the new backend. Merging it earlier gives
  admins a form that 404s.
- **solid-ui** last. It renders whatever the backend says is available, so it is
  inert until the backend is configured.

The portal and the app do not depend on each other, but doing the portal first
means you can configure and check the switches before any user can see a route.

Then, per environment (**QA first, and all the way through**):

1. Deploy the backend with the addresses still empty. Nothing changes. This
   de-risks the deploy from the feature.
2. Deploy the contracts (§3) and grant the role (§4).
3. Fill the addresses in, redeploy. Still nothing user-visible: both switches
   are off.
4. Turn on `lock.enabled` from the portal. Exercise it end to end:
   `approve` → `lock` → the tier appears → the Earn tile shows the position →
   `withdrawFor` once matured.
5. Turn on `subscription.enabled`. Exercise: `enableModule` + `subscribe` in one
   batch → `charge` → the tier appears → `cancel` → it runs to period end.
6. Only then repeat on prod. Leave `TIER_SUBSCRIPTION_MODULE_ADDRESS` empty in
   prod until QA has completed a real charge: the module moves real USDC out of
   real user Safes and its `revenueTreasury` is immutable, so a wrong deployment
   cannot be redirected, only disabled.

Ultra stays lock-only for as long as `ultra_annual_usd` is `0`. Pricing it in
the portal is what would make it purchasable for cash — deliberately a switch,
not a code change.

---

## 7. Smoke test

Against a QA Safe, after §4. `canCharge` is the lens that answers "would a
charge work, and if not, why" in one call, so use it rather than sending a
charge and reading a revert:

```bash
SAFE=0x…      # a QA user's Safe
AMOUNT=199000000   # $199 in USDC base units

cast call $MODULE "canCharge(address,uint256)(bool,string)" $SAFE $AMOUNT --rpc-url fuse
```

The string is the whole diagnosis: `not subscribed`, `module not enabled`,
`too soon`, `exceeds mandate`, `exceeds org ceiling`, `insufficient balance`,
`cancelled`, `safe paused`, `module paused`.

For the lock side:

```bash
cast call $LOCK "lockedSharesOf(address)(uint256)" $SAFE --rpc-url fuse
cast call $LOCK "lockedAssetsOf(address)(uint256)" $SAFE --rpc-url fuse   # in FUSE, via getRate()
cast call $LOCK "nextUnlockOf(address)(uint64,uint256)" $SAFE --rpc-url fuse
cast call $LOCK "maturedSharesOf(address)(uint256)" $SAFE --rpc-url fuse  # what withdraw() returns now
```

A user's `lock` is two calls batched by the app — `approve(LOCK, shares)` on the
share token, then `lock(shares)` — because the contract pulls with
`safeTransferFrom`. A `lock` that reverts with no allowance set is the batch
having been split, not a contract fault.

---

## 8. Kill switches, in increasing order of severity

Reach for the leftmost one that works.

| Situation | Action | Effect |
| --- | --- | --- |
| Something looks wrong, cause unknown | Turn the app-config switch off | Route disappears from the app. Existing locks and subscriptions carry on. Nothing on-chain changes |
| Billing is misbehaving | Clear `TIER_SUBSCRIPTION_MODULE_ADDRESS`, redeploy | The backend stops charging entirely. Memberships survive |
| One Safe is being charged wrongly | `setSafePaused(safe, true)` | That Safe only. Reversible |
| Charges must stop chain-wide, now | `pause()` on the module | Every charge reverts. Subscriptions survive, `cancel` still works |
| Mandates are too large | `setMaxChargeAmount(lower)` | Binds existing mandates too — a live throttle, not just a new-signups limit |
| Locking must stop | `pause()` on the lock | New locks refused. **Withdrawals keep working** — that is deliberate and not a gap |

Nothing here can strand a user's shares. `withdraw` is never gated, and
`withdrawFor` means a keeper can return a matured position even if the user
never comes back.

Note the asymmetry: the module's `pause` stops us taking money, and
`disableModule` on the Safe — which the user can do from any Safe client
without us — stops it absolutely. Only one of those is ours.
