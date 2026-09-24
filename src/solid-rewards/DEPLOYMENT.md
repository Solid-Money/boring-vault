# Deploying rewards v3

Step-by-step runbook for `SolidTierLock`, `SolidSubscriptionModule` and
`SolidTierLockZap` on Fuse (chain 122), and for turning the two upgrade routes
on afterwards.

Read [README.md](./README.md) first for what the contracts do and why they are
shaped this way. This file is only how to get them live.

Work through steps 1–14 in order. Everything after them is reference: look
things up there, do not work through it.

> **Three values are immutable once the constructor runs** — the module's
> `billingToken` and `revenueTreasury`, and the lock's share token. None of them
> has a setter. A wrong value there is not a config fix, it is a redeploy and a
> migration of everyone who subscribed in between. Step 5 exists to stop that.

**Do QA first, all the way to step 14, before you start prod.**

---

## Step 1 — Install Foundry so it survives a new terminal

The installer drops `forge`, `cast`, `anvil` and `chisel` into `~/.foundry/bin`
and appends a PATH line to **one** startup file, chosen from `$SHELL`. That is
the whole reason this goes wrong: the file it picks is often not one your shell
reads, so the tools work in the window you installed them in and vanish in the
next one.

Run all four blocks. They are idempotent — re-running them is harmless.

```bash
# 1a. Install. Writes ~/.foundry/bin/{forge,cast,anvil,chisel}.
curl -L https://foundry.paradigm.xyz | bash
```

```bash
# 1b. Put that directory on PATH for every future shell. Appends one line to
#     each startup file that already exists and does not mention it yet.
#     Files that do not exist are left alone on purpose: creating
#     ~/.bash_profile is itself enough to stop bash reading ~/.profile.
for rc in ~/.zshenv ~/.zshrc ~/.bashrc ~/.bash_profile ~/.profile; do
  [ -f "$rc" ] && ! grep -qF '.foundry/bin' "$rc" \
    && printf '\nexport PATH="$HOME/.foundry/bin:$PATH"\n' >> "$rc" \
    && echo "added to $rc"
done
```

```bash
# 1c. ...and for the shell you are in right now, which read those files before
#     you edited them. Skipping this is what makes `foundryup: command not
#     found` immediately after a successful install.
export PATH="$HOME/.foundry/bin:$PATH"
```

```bash
# 1d. Now install the toolchain itself and check it.
foundryup
forge --version        # 1.5.x or newer
cast  --version
```

Open a **new** terminal and run `forge --version` again. If it answers there,
step 1 is done for good and you never repeat it.

> **`forge: command not found` in a new terminal does not mean the install was
> lost.** The binaries are still on disk — `ls ~/.foundry/bin` will show them,
> and they survive reboots. What is missing is the PATH entry. Re-running the
> installer reinstalls the same four files into the same directory and edits the
> same startup file, which is why it appears to need reinstalling every session:
> it never fixed the PATH, so it never lasted. Run block 1b instead, then 1c,
> then open a new terminal.
>
> The usual culprit is bash on macOS: every new Terminal window is a *login*
> shell, which reads `~/.bash_profile` and ignores `~/.bashrc` — and `~/.bashrc`
> is where the installer writes. Block 1b covers both.

> **If `foundryup` fails to download** (a 403 on the attestation bundle, or any
> proxy that blocks GitHub release artifacts), take the release tarball
> directly and unpack it into the same directory. PATH is already set, so
> nothing else changes:
>
> ```bash
> mkdir -p ~/.foundry/bin && cd "$(mktemp -d)"
> curl -fsSL -o foundry.tar.gz \
>   https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz
> tar -xzf foundry.tar.gz -C ~/.foundry/bin
> forge --version
> ```
>
> Swap `linux_amd64` for `darwin_arm64` on an Apple Silicon Mac.

---

## Step 2 — Clone the repo and fetch the three submodules

```bash
git clone git@github.com:Solid-Money/boring-vault.git && cd boring-vault
git submodule update --init --depth 1 lib/solmate lib/openzeppelin-contracts lib/forge-std
```

Only those three are needed for these contracts. The rest of the repo's `lib/`
is large and unrelated, so do not run a bare `git submodule update --init`.

The compiler profile is pinned in `foundry.toml`: **solc 0.8.21,
`evm_version = london`, optimizer on at 200 runs.** London is deliberate and
matters on Fuse — do not raise it to `paris` or `shanghai` for this deployment.
See reference C for why.

`foundry.toml` already maps the `fuse` alias to `${FUSE_RPC_URL}`, so
`--rpc-url fuse` works everywhere below once step 4 is done. Hardhat is present
in the repo for unrelated work and is **not** used for this deployment.

---

## Step 3 — Run the tests

```bash
forge test --match-path "test/Solid*.t.sol" --skip "script/*"
```

Expect **75 passing, 0 failed**, in well under a second. No fork is needed.

> **`--skip "script/*"` is required, not optional.** Two files —
> `script/GigaDeployDecoderAndSanitizer.s.sol` and
> `script/DeployDecodersAndSanitizersWithNoConstructorArgs.s.sol` — import
> `LombardBTCMinterDecoderAndSanitizer.sol` where the file on disk is
> `LombardBtcMinterDecoderAndSanitizer.sol`. It builds on a case-insensitive
> filesystem and fails on Linux and in CI. `--match-path` alone does **not**
> step around it: forge still compiles the whole project before it selects
> tests, so you get `ParserError: Source ... not found` and no test run at all.
> Unrelated to these contracts.

---

## Step 4 — Fill in `.env`

```bash
cp sample.env .env
```

Then set these. Values in the table are production; see reference F for QA.

| variable | what it is | production value |
| --- | --- | --- |
| `FUSE_RPC_URL` | the RPC the `fuse` alias resolves to | `https://rpc.fuse.io` |
| `PRIVATE_KEY` | deployer EOA. Needs native FUSE for gas and nothing else | — |
| `OWNER` | owns both contracts. **The Safe, not the deployer** | `0xBA308f2919aa20fbD58fc7406451077fe32F1F29` |
| `SOFUSE_VAULT` | the soFUSE BoringVault — the share the lock escrows | `0xb33c8F0b0816fd147FCF896C594a3ef408845e2C` |
| `SOFUSE_ACCOUNTANT` | its `AccountantWithRateProviders` | `0xb29B5F760d38587f7F4C896C458B9EEB5CAd9C0C` |
| `USDC` | billing asset. **Immutable on the module** | `0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9` |
| `REVENUE_TREASURY` | the only address the module can ever pay. **Immutable** | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` |
| `LOCK_DURATION_SECONDS` | the term. Changeable later, never for a lock already taken | `31536000` |
| `MIN_LOCK_SHARES` | dust floor, in 18-dp shares. **Not a tier price** | `1000000000000000000` |
| `MAX_CHARGE_AMOUNT` | ceiling on one charge, in USDC base units. **Not the fee** | `500000000` |

`OWNER` is an argument to the constructor, not `msg.sender` — the deployer EOA
holds no rights at all once it has run. Set it to the multisig. Reference A has
the full list of what that owner can and cannot do.

`MIN_LOCK_SHARES` and `MAX_CHARGE_AMOUNT` are the two values people most often
mistake for prices. Neither is. See step 12 for where the real numbers live.

---

## Step 5 — Pre-flight: check every constructor argument against the chain

Do this **before** broadcasting. `cast` reads from the same RPC the deploy will
use, so anything wrong here is wrong there.

```bash
source .env

# The share token must be the soFUSE BoringVault, 18 decimals.
cast call $SOFUSE_VAULT "decimals()(uint8)" --rpc-url fuse        # expect 18
cast call $SOFUSE_VAULT "symbol()(string)"  --rpc-url fuse        # expect soFUSE

# The accountant must answer getRate() — a revert means the wrong address and
# the lock's USD display is dead on arrival — AND it must price THIS vault.
cast call $SOFUSE_ACCOUNTANT "getRate()(uint256)" --rpc-url fuse
cast call $SOFUSE_ACCOUNTANT "vault()(address)"   --rpc-url fuse  # == $SOFUSE_VAULT

# The billing asset must be 6-decimal USDC.e. MAX_CHARGE_AMOUNT is in ITS base
# units, so this decides whether 500000000 means $500 or $500,000,000,000.
cast call $USDC "decimals()(uint8)" --rpc-url fuse                # expect 6
cast call $USDC "symbol()(string)"  --rpc-url fuse                # expect USDC

# The owner must exist on Fuse and be the multisig.
cast code $OWNER --rpc-url fuse | head -c 20                      # non-empty for a Safe

# The treasury just has to be an address you control that can receive an ERC-20.
# An EOA is fine and returns empty code — this read is to catch a typo'd or
# zero address, not to require a contract.
cast call $USDC "balanceOf(address)(uint256)" $REVENUE_TREASURY --rpc-url fuse
```

> **The `accountant.vault()` line is the one that matters.** There are **two**
> soFUSE vaults on Fuse, each with its own accountant, and they are not
> interchangeable. Both are called "Solid Fuse" and both use the symbol soFUSE,
> so `symbol()` cannot tell them apart. Pairing a vault with the other one's
> accountant compiles, deploys, and returns a plausible rate — it is simply the
> wrong one, and `lockedAssetsOf` will price every position with it.
>
> | | QA | Production |
> | --- | --- | --- |
> | soFUSE vault | `0xDA737B0C12a08D85C973F10f25459F07F2BB2882` | `0xb33c8F0b0816fd147FCF896C594a3ef408845e2C` |
> | its accountant | `0xc864e169a1d40b957170E6c848BbcE49f28b361B` | `0xb29B5F760d38587f7F4C896C458B9EEB5CAd9C0C` |
> | supply, at time of writing | ~5,025 | ~27,878,092 |

Re-derive the addresses from helm (`SOFUSE_VAULT_ADDRESS_FUSE`,
`SOFUSE_ACCOUNTANT_ADDRESS_FUSE`, `REVENUE_WALLET_ADDRESS`) rather than trusting
this file if time has passed.

---

## Step 6 — Deploy the lock and the module

Dry-run first. Without `--broadcast` it prints both addresses and sends nothing:

```bash
forge script script/DeploySolidRewards.s.sol --rpc-url fuse --private-key $PRIVATE_KEY
```

Then for real:

```bash
forge script script/DeploySolidRewards.s.sol \
  --rpc-url fuse \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --slow
```

**Record the two addresses it logs.** If the run ends in
`failed to fetch block ... missing field 'mixHash'`, the contracts are deployed
anyway — do **not** re-run, you will deploy a second copy. Reference C explains
it and step 7 confirms it.

---

## Step 7 — Check what actually landed

```bash
export LOCK=0x…      # SolidTierLock, from step 6
export MODULE=0x…    # SolidSubscriptionModule, from step 6

cast call $LOCK   "lockToken()(address)"       --rpc-url fuse   # == $SOFUSE_VAULT
cast call $LOCK   "lockDuration()(uint64)"     --rpc-url fuse   # == 31536000
cast call $LOCK   "owner()(address)"           --rpc-url fuse   # == $OWNER
cast call $LOCK   "authority()(address)"       --rpc-url fuse   # == 0x0, for now

cast call $MODULE "revenueTreasury()(address)" --rpc-url fuse   # == $REVENUE_TREASURY
cast call $MODULE "billingToken()(address)"    --rpc-url fuse   # == $USDC
cast call $MODULE "maxChargeAmount()(uint128)" --rpc-url fuse   # == $MAX_CHARGE_AMOUNT
cast call $MODULE "owner()(address)"           --rpc-url fuse   # == $OWNER
```

`revenueTreasury` and `billingToken` are the immutable pair. If either is wrong,
stop here and redeploy — there is no setter, and every subscription taken
against a wrong one has to be migrated.

---

## Step 8 — Verify the source on Blockscout (optional, worth doing)

Source verification is optional on Fuse — `foundry.toml` ships every
`[etherscan]` entry commented out — but it lets the owner multisig's signers
read what they are approving.

```bash
forge verify-contract $LOCK SolidTierLock \
  --chain-id 122 --verifier blockscout \
  --verifier-url https://explorer.fuse.io/api \
  --constructor-args $(cast abi-encode \
      "constructor(address,address,address,uint64,uint256)" \
      $OWNER $SOFUSE_VAULT $SOFUSE_ACCOUNTANT $LOCK_DURATION_SECONDS $MIN_LOCK_SHARES)

forge verify-contract $MODULE SolidSubscriptionModule \
  --chain-id 122 --verifier blockscout \
  --verifier-url https://explorer.fuse.io/api \
  --constructor-args $(cast abi-encode \
      "constructor(address,address,address,uint128)" \
      $OWNER $USDC $REVENUE_TREASURY $MAX_CHARGE_AMOUNT)
```

---

## Step 9 — Grant the biller role

Nothing bills until this is done. Until then `charge` is owner-only, which is
the correct default: a mis-set env var cannot hand billing rights to an address
nobody meant.

### 9a. Find the address that gets the role

**The backend's ERC-4337 smart account** — not the EOA that signs it, and never
a user Safe.

`TierBillingService` submits through `aaOperations.execute(...)`, so at the
module `msg.sender` is that smart account. The EOA only signs the UserOperation
and never appears as the caller; grant the role to it and every charge reverts
on `requiresAuth`. Same gate `CASH_SWEEP_USE_AA` documents in helm for
`SolidCashModule.spend`, for the same reason.

A user Safe is wrong for a different reason: the biller chooses *which* Safe is
charged, so a Safe holding the role could charge every other subscriber.

Get the address from the admins-service:

```
GET /admin/v1/wallets/status        (behind FirebaseAuthGuard)
```

Look for **"Direct Deposit Smart Account"** (QA) or **"Direct Deposit AA
Wallet"** (prod) — same account, different label. It is also the Wallets page in
the admin dashboard if you would rather click than curl.

The address is derived from `SMART_ACCOUNT_SIGNER_KEY`, so **QA and prod have
different ones.** Never copy prod's into a QA grant.

> `AAOperationsService` also logs it at boot as
> `Smart Account ready on chain 122: 0x…`, but only once something has used
> chain 122 — the per-chain client is lazily initialised, which is why the line
> appears on prod and not on QA. The endpoint above forces that init across
> chains 1, 122, 137, 8453 and 42161, so calling it both returns the address and
> makes the log line appear from then on.

### 9b. Pick the authority and the role id

`setRoleCapability` and `setUserRole` are sent by the **authority's own owner**,
which is not necessarily the owner of your contracts. Read it rather than assume
it:

```bash
export AUTH=0x058CA721e21492ad72979f9Fb52410f6DA588800   # prod; see reference F for QA
cast call $AUTH "owner()(address)" --rpc-url fuse        # must be your $OWNER
```

If it is not, you cannot write to that authority. Deploy your own:

```bash
forge create src/fuse/FuseRolesAuthority.sol:FuseRolesAuthority \
  --rpc-url fuse --private-key $PRIVATE_KEY --broadcast \
  --constructor-args $OWNER 0x0000000000000000000000000000000000000000
```

`--broadcast` is required on `forge create` in Foundry 1.x. Without it the
command simulates, prints an address, and sends nothing — so the address it
gives you has no code at it.

Roles are plain `uint8`s held by the authority, not constants in these
contracts, so nothing in the code has to agree with the number. On the live
`FuseRolesAuthority` roles **1, 2 and 3 are taken** (cash module, card manager),
so **use role 4** for the biller. Confirm it is free:

```bash
cast call $AUTH "getRolesWithCapability(address,bytes4)(bytes32)" \
  $MODULE 0x1e1d709a --rpc-url fuse
# 0x00…00 = nothing holds charge() on this module yet
```

`0x1e1d709a` is `charge(address,bytes32,uint256)`. Re-derive it any time with
`cast sig "charge(address,bytes32,uint256)"`.

### 9c. Send the three transactions

Set everything up first, in one shell:

```bash
set -u                                    # see the warning below
export MODULE=0x…                         # from step 6
export AUTH=0x058CA721e21492ad72979f9Fb52410f6DA588800
export BILLER=0x…                         # the smart account from 9a
export CHARGE_SELECTOR=0x1e1d709a
export BILLER_ROLE=4
```

**If the owner is an EOA** (QA). Import the key into a keystore once, so it is
never on a command line, in your shell history, or in the environment:

```bash
cast wallet import solid-qa --interactive     # once; asks for the key and a password
export DEPLOYER=solid-qa
```

Then, in this order:

```bash
# 1 of 3 — point the module at the authority. Sent by the MODULE's owner.
cast send --account $DEPLOYER "$MODULE" \
  "setAuthority(address)" "$AUTH" \
  --rpc-url fuse
```

```bash
# 2 of 3 — let role 4 call charge() on this module. Sent by the AUTHORITY's owner.
cast send --account $DEPLOYER "$AUTH" \
  "setRoleCapability(uint8,address,bytes4,bool)" \
  "$BILLER_ROLE" "$MODULE" "$CHARGE_SELECTOR" true \
  --rpc-url fuse
```

```bash
# 3 of 3 — give role 4 to the backend's smart account.
cast send --account $DEPLOYER "$AUTH" \
  "setUserRole(address,uint8,bool)" \
  "$BILLER" "$BILLER_ROLE" true \
  --rpc-url fuse
```

Transaction 1 must land before 3 means anything: a role granted on an authority
the module does not consult does nothing.

**If the owner is a Safe** (production). Build the same three calls as calldata,
open the Safe at `$OWNER`, and paste each into **Transaction Builder** against
its target with value 0. Batch all three into one multisend, so the window where
the authority is attached but the role is not never exists.

```bash
cast calldata "setAuthority(address)" "$AUTH"                        # to: $MODULE
cast calldata "setRoleCapability(uint8,address,bytes4,bool)" \
  "$BILLER_ROLE" "$MODULE" "$CHARGE_SELECTOR" true                   # to: $AUTH
cast calldata "setUserRole(address,uint8,bool)" \
  "$BILLER" "$BILLER_ROLE" true                                      # to: $AUTH
```

### 9d. Confirm

```bash
cast call "$AUTH" "doesUserHaveRole(address,uint8)(bool)" "$BILLER" "$BILLER_ROLE" --rpc-url fuse
cast call "$AUTH" "canCall(address,address,bytes4)(bool)" "$BILLER" "$MODULE" "$CHARGE_SELECTOR" \
  --rpc-url fuse
# both true
```

Both false? Reference D says which transaction is missing.

> Do **not** grant this role `pause`, `setMaxChargeAmount`, `setSafePaused`,
> `rescue`, `setAuthority` or `transferOwnership`. The backend needs exactly one
> selector. `transferOwnership` in particular is `requiresAuth`, not owner-only,
> so a role holding it can take the contract.

**The backend needs no role on `SolidTierLock`.** Everything it calls there is
permissionless: `lockedSharesOf`, `lockedAssetsOf`, `maturedSharesOf`,
`nextUnlockOf`, `getLocks` and `lockDuration` are views, and `withdrawFor` — the
unlock cron's only write — is deliberately callable by anyone, because the
shares can only ever go to the account that locked them. The only thing that
needs a role on the lock is the zap, which is step 11.

---

## Step 10 — Deploy the zap (optional: the one-press upgrade)

Skip this and a user pays a tier's lock by depositing into Savings first and
coming back once the shares have landed. That works; it is two signatures and a
wait.

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
user's and returnable only to the user, exactly as a direct `lock` would be.

### 10a. First: the lock must be one that has `lockFor`

`lockFor` was added to `SolidTierLock` alongside the zap. **A lock deployed
before that does not have the function at all**, and no amount of role granting
conjures it: `setRoleCapability` happily writes a mapping entry against a
selector that is not in the contract's dispatcher, `canCall` starts answering
true, and the first zap still reverts.

Check the deployed bytecode before anything else — this is the one failure that
looks like a permissions problem and is not:

```bash
cast code $LOCK --rpc-url fuse | grep -c 3d96e276     # 1 = lockFor is there, 0 = redeploy
```

A `0` means redeploy `SolidTierLock` from a build that includes `lockFor`, point
`TIER_LOCK_ADDRESS` at the new one, and repeat step 9 for it. Positions in the
old lock are not lost — `withdrawFor` is permissionless and still returns them
to whoever locked — but they are in the old contract, so migrate before anyone
locks into the one you are replacing.

### 10b. Deploy

```bash
export TIER_LOCK=$LOCK
export SOFUSE_TELLER=0x…   # the Teller that MINTS soFUSE — not the vault

forge script script/DeploySolidTierLockZap.s.sol \
  --rpc-url fuse --private-key $PRIVATE_KEY --broadcast --slow
```

The constructor refuses a Teller whose `vault()` is not the share the lock
escrows, so a zap wired to the wrong Teller fails here rather than stranding the
first user's deposit in the periphery.

### 10c. Check what landed

```bash
export ZAP=0x…

cast call $ZAP "lock()(address)"       --rpc-url fuse   # == $LOCK
cast call $ZAP "teller()(address)"     --rpc-url fuse   # == $SOFUSE_TELLER
cast call $ZAP "shareToken()(address)" --rpc-url fuse   # == $SOFUSE_VAULT
cast call $ZAP "vault()(address)"      --rpc-url fuse   # == $SOFUSE_VAULT, same address

# An atomic deposit-and-lock only works while the Teller's share lock period is
# zero: a non-zero one makes the minted shares untransferable for that long, and
# the zap's lockFor in the same transaction would revert.
cast call $SOFUSE_TELLER "shareLockPeriod()(uint64)" --rpc-url fuse   # must be 0
```

The zap enforces this itself now: its constructor refuses a Teller that has a
share lock, and `zapAndLock` re-reads it on every minting call and reverts with
`SolidTierLockZap__ShareLockActive`. So a non-zero period cannot be deployed
against, and one set later gives a named error rather than a bare
`TRANSFER_FROM_FAILED` from inside the lock. The read above is still worth
doing: it tells you before you spend the gas.

`shareLockPeriod` is 0 on both QA and prod today. If it is ever set non-zero,
turn the zap off (clear the backend's `TIER_LOCK_ZAP_ADDRESS`) rather than
leaving users a button that reverts — the share-token path would still work,
but the two deposit paths would not.

### 10d. Verify the zap source on Blockscout (optional)

Same three arguments `DeploySolidTierLockZap.s.sol` was given, in the same
order:

```bash
forge verify-contract $ZAP SolidTierLockZap \
  --chain-id 122 --verifier blockscout \
  --verifier-url https://explorer.fuse.io/api \
  --constructor-args $(cast abi-encode \
      "constructor(address,address,address)" \
      $OWNER $TIER_LOCK $SOFUSE_TELLER)
```

---

## Step 11 — Grant the zap `lockFor`

Same shape as step 9, on the lock instead of the module, and with a different
authority on QA. Three transactions.

### 11a. Pick the authority and the role id

**This is where the grant most often goes to the wrong place.** The authority
the *lock* consults is the only one that counts, and it may not be the one step
9 used. Read both:

```bash
cast call $LOCK "authority()(address)" --rpc-url fuse   # what the lock consults (0x0 before tx 1)
cast call $AUTH "owner()(address)"     --rpc-url fuse   # must be your $OWNER, or you cannot write
```

On QA that is the separately deployed
`0x35d231ad40bFab54b8aCAec3E4Ef4A6A0682246b`, owned by the QA owner EOA — **not**
the production `0x058CA721e21492ad72979f9Fb52410f6DA588800`, which is owned by
the prod Safe and reverts every write you send it. Granting on the wrong
authority is silent: the grant lands, and the lock — which consults the other
one — never sees it.

Roles 1–4 are taken (cash module, card manager, biller), so **use role 5**.
Confirm it is free:

```bash
cast call $AUTH "getRolesWithCapability(address,bytes4)(bytes32)" \
  $LOCK 0x3d96e276 --rpc-url fuse
# 0x00…00 = nothing holds lockFor() on this lock yet
```

`0x3d96e276` is `lockFor(address,uint256)` — `cast sig "lockFor(address,uint256)"`.

### 11b. Send the three transactions

```bash
set -u
export LOCK=0x…                                          # from step 6
export ZAP=0x…                                           # from step 10
export AUTH=0x35d231ad40bFab54b8aCAec3E4Ef4A6A0682246b   # QA; yours on prod
export LOCK_FOR_SELECTOR=0x3d96e276
export ZAP_ROLE=5
export DEPLOYER=solid-qa                                 # the keystore name from 9c
```

```bash
# 1 of 3 — point the lock at the authority. Sent by the LOCK's owner.
cast send --account $DEPLOYER "$LOCK" \
  "setAuthority(address)" "$AUTH" \
  --rpc-url fuse
```

```bash
# 2 of 3 — let role 5 call lockFor() on this lock. Sent by the AUTHORITY's owner.
cast send --account $DEPLOYER "$AUTH" \
  "setRoleCapability(uint8,address,bytes4,bool)" \
  "$ZAP_ROLE" "$LOCK" "$LOCK_FOR_SELECTOR" true \
  --rpc-url fuse
```

```bash
# 3 of 3 — give role 5 to the zap, and to nothing else.
cast send --account $DEPLOYER "$AUTH" \
  "setUserRole(address,uint8,bool)" \
  "$ZAP" "$ZAP_ROLE" true \
  --rpc-url fuse
```

For a Safe owner, the same three as calldata for Transaction Builder:

```bash
cast calldata "setAuthority(address)" "$AUTH"                            # to: $LOCK
cast calldata "setRoleCapability(uint8,address,bytes4,bool)" \
  "$ZAP_ROLE" "$LOCK" "$LOCK_FOR_SELECTOR" true                          # to: $AUTH
cast calldata "setUserRole(address,uint8,bool)" "$ZAP" "$ZAP_ROLE" true  # to: $AUTH
```

Transaction 1 is the one to think about. Until now the lock has had no
authority, which made `setLockDuration`, `setMinLockShares`, `pause` and
`rescue` owner-only. Attaching an authority does not change that by itself —
they stay owner-only until someone grants a role for them — but it is the moment
they *become* grantable. Grant role 5 the `lockFor` selector and nothing else.

### 11c. Confirm

```bash
cast call "$AUTH" "doesUserHaveRole(address,uint8)(bool)" "$ZAP" "$ZAP_ROLE" --rpc-url fuse
cast call "$AUTH" "canCall(address,address,bytes4)(bool)" "$ZAP" "$LOCK" "$LOCK_FOR_SELECTOR" \
  --rpc-url fuse
# both true
```

Either false? Reference D.

### Turning it off later

`setUserRole($ZAP, 5, false)` stops new zaps immediately and touches no position
already taken. Clearing the backend's `TIER_LOCK_ZAP_ADDRESS` is the softer
version: the app stops offering the one-press route and falls back to
deposit-then-lock, with no on-chain transaction at all.

---

## Step 12 — Point the backend at the addresses

`solid-backend`, `accounts-service`. Five env vars, already present and empty in
`helm/values/{qa,prod}.yaml` and `.env.example`:

```yaml
TIER_LOCK_ADDRESS: "0x…"                  # $LOCK
TIER_LOCK_ZAP_ADDRESS: "0x…"              # $ZAP — leave empty until step 11 is confirmed
TIER_SUBSCRIPTION_MODULE_ADDRESS: "0x…"   # $MODULE
TIER_BILLING_TOKEN_ADDRESS: "0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9"
TIER_MEMBERSHIP_FUSE_RPC_URL: "https://rpc.fuse.io"
```

- `TIER_LOCK_ZAP_ADDRESS` is the app's switch for the one-press upgrade. Empty
  means the app asks the user to deposit into Savings first and come back. Set it
  only once step 11c came back true twice — an address set without the role gives
  users a button that reverts.
- `TIER_BILLING_TOKEN_ADDRESS` **must equal the module's immutable
  `billingToken`.** The module can only ever move that one token, so a mismatch
  means every balance check runs against an asset the charge will not touch:
  `canCharge` says yes and the charge reverts.
- An empty address is not an error. The tier resolver reads it as "this route
  does not exist yet" and falls back to points and staked FUSE, which is exactly
  v2's behaviour — which is why the backend can ship before the contracts exist.

The UI needs no configuration at all: it reads all four addresses and the chain
id from the backend's membership state, so there is one place to get this wrong
instead of three.

---

## Step 13 — Turn the routes on, one at a time

The switches live in Mongo, not in env, and are edited from the admin portal
(`/rewards-config` → "Tier Membership (v3)"). All default to v2's behaviour, so
nothing is user-visible until you change them here.

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
what binds. Keep them equal or the app promises a term it does not set.

Order, per environment:

1. Deploy the backend with the addresses still empty. Nothing changes. This
   de-risks the deploy from the feature.
2. Fill the addresses in (step 12) and redeploy. Still nothing user-visible:
   both switches are off.
3. Turn on `lock.enabled`. Exercise it end to end: `approve` → `lock` → the tier
   appears → the Earn tile shows the position → `withdrawFor` once matured. If
   the zap is deployed, exercise the one-press path too: it should take native
   FUSE, WFUSE and soFUSE in a single signature.
4. Turn on `subscription.enabled`. Exercise: `enableModule` + `subscribe` in one
   batch → `charge` → the tier appears → `cancel` → it runs to period end.
5. Only then repeat on prod. Leave `TIER_SUBSCRIPTION_MODULE_ADDRESS` empty in
   prod until QA has completed a real charge: the module moves real USDC out of
   real user Safes and its `revenueTreasury` is immutable, so a wrong deployment
   cannot be redirected, only disabled.

> **Two thresholds people expect to find in the contracts and will not.**
>
> - **`MIN_LOCK_SHARES` is a dust floor, not a tier price.** `SolidTierLock` has
>   no idea what a tier is. The tier comes from the backend reading
>   `lockedAssetsOf` and comparing it against `fuse_staking.tier2.amount`
>   (50,000 FUSE → Prime) and `fuse_staking.tier3.amount` (400,000 FUSE →
>   Ultra). Locking the minimum buys a lock and no tier at all.
> - **`MAX_CHARGE_AMOUNT` is a ceiling, not a price.** The annual fee is
>   `tier_membership.subscription.*_annual_usd`. The ceiling only caps how large
>   any single charge may be — and binds existing mandates when lowered.
>
> So the config values and the constructor arguments have to agree by hand: a
> `MAX_CHARGE_AMOUNT` below the configured annual fee makes every charge revert
> on `ExceedsOrgCeiling`. Thresholds changed in config need no contract change
> at all.

Ultra stays lock-only for as long as `ultra_annual_usd` is `0`. Pricing it in
the portal is what makes it purchasable for cash — deliberately a switch, not a
code change.

---

## Step 14 — Smoke test

Against a QA Safe. `canCharge` is the lens that answers "would a charge work,
and if not, why" in one call, so use it rather than sending a charge and reading
a revert:

```bash
export SAFE=0x…            # a QA user's Safe
export AMOUNT=199000000    # $199 in USDC base units

cast call $MODULE "canCharge(address,uint256)(bool,string)" $SAFE $AMOUNT --rpc-url fuse
```

The string is the whole diagnosis: `not subscribed`, `module not enabled`,
`too soon`, `exceeds mandate`, `exceeds org ceiling`, `insufficient balance`,
`cancelled`, `safe paused`, `module paused`.

For the lock side:

```bash
cast call $LOCK "lockedSharesOf(address)(uint256)"     $SAFE --rpc-url fuse
cast call $LOCK "lockedAssetsOf(address)(uint256)"     $SAFE --rpc-url fuse  # in FUSE, via getRate()
cast call $LOCK "nextUnlockOf(address)(uint64,uint256)" $SAFE --rpc-url fuse
cast call $LOCK "maturedSharesOf(address)(uint256)"    $SAFE --rpc-url fuse  # what withdraw() returns now
```

A soFUSE `lock` is two calls batched by the app — `approve(LOCK, shares)` on the
share token, then `lock(shares)` — because the contract pulls with
`safeTransferFrom`. A `lock` that reverts with no allowance set is the batch
having been split, not a contract fault. The zap path is one call and needs no
prior approval for native FUSE.

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

---
---

# Reference

## A. Who owns what

All three contracts are `solmate/Auth`, constructed as `Auth(OWNER, Authority(0))`.
None is permissionless and none is ownerless.

`requiresAuth` passes if the caller is `owner`, **or** if an attached `Authority`
says the caller may call that selector. Until an authority is attached, the
owner is the only address that can reach anything gated.

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
  transfers, so only a stray donation is reachable. No value of any setter
  reaches a user's lock.
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
- `zapAndLock` on the zap. It credits `msg.sender`, so a caller can only ever
  fund their own lock.

> **Never grant `transferOwnership` to a role.** It is `requiresAuth`, not
> owner-only, so a role holding it can take the contract.

---

## B. Kill switches, in increasing order of severity

Reach for the leftmost one that works.

| Situation | Action | Effect |
| --- | --- | --- |
| Something looks wrong, cause unknown | Turn the app-config switch off | Route disappears from the app. Existing locks and subscriptions carry on. Nothing on-chain changes |
| The one-press upgrade is misbehaving | Clear `TIER_LOCK_ZAP_ADDRESS`, redeploy | App falls back to deposit-then-lock. Nothing on-chain changes |
| The zap must stop, now | `setUserRole($ZAP, 5, false)` | Every `zapAndLock` reverts. Positions already taken are untouched |
| Billing is misbehaving | Clear `TIER_SUBSCRIPTION_MODULE_ADDRESS`, redeploy | The backend stops charging entirely. Memberships survive |
| One Safe is being charged wrongly | `setSafePaused(safe, true)` | That Safe only. Reversible |
| Charges must stop chain-wide, now | `pause()` on the module | Every charge reverts. Subscriptions survive, `cancel` still works |
| Mandates are too large | `setMaxChargeAmount(lower)` | Binds existing mandates too — a live throttle, not just a new-signups limit |
| Locking must stop | `pause()` on the lock | New locks refused. **Withdrawals keep working** — deliberate, not a gap |

Nothing here can strand a user's shares. `withdraw` is never gated, and
`withdrawFor` means a keeper can return a matured position even if the user
never comes back.

Note the asymmetry: the module's `pause` stops us taking money, and
`disableModule` on the Safe — which the user can do from any Safe client without
us — stops it absolutely. Only one of those is ours.

---

## C. Two Fuse warnings you will see, and why neither is a problem

### `EIP-3855 is not supported ... Unsupported Chain IDs: 122`

Forge checks the chain for PUSH0 (EIP-3855, a Shanghai opcode) and warns because
solc ≥ 0.8.20 emits it *by default*. This repo does not compile by default:
`foundry.toml` pins `evm_version = 'london'`, which predates PUSH0, so the
compiler cannot emit the opcode at all. The warning is about the chain, not
about this bytecode.

Verify rather than trust it. Counting `0x5f` bytes with `grep` gives false
positives — `5f` also appears inside push *immediates* — so walk the runtime
code as opcodes and skip each push's data:

```bash
cat > /tmp/push0.py <<'PY'
import sys
code = sys.stdin.read().strip().removeprefix("0x")
b, i, n = bytes.fromhex(code), 0, 0
while i < len(b):
    op = b[i]
    if op == 0x5f: n += 1
    i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
print(n)
PY

cast code $LOCK   --rpc-url fuse | python3 /tmp/push0.py    # 0
cast code $MODULE --rpc-url fuse | python3 /tmp/push0.py    # 0
cast code $ZAP    --rpc-url fuse | python3 /tmp/push0.py    # 0
```

All three contain **zero** PUSH0 opcodes when built with this profile. What
would break is raising `evm_version` — don't, for Fuse.

### `failed to fetch block ... missing field 'mixHash'`

Fuse runs Nethermind with Aura (PoA), whose block headers carry `step` and
`signature` in place of `mixHash` and `nonce`. Alloy — the RPC layer under forge
and cast — expects a post-merge header and fails to deserialise.

**This is a receipt-fetching failure, not a transaction failure.** `forge
script` has already broadcast by the time it happens; a progress line showing
`2/2 txes` and `1/2 receipts` means both transactions are on chain and forge
lost track of one of them.

Do not re-run the script — you will deploy a second copy. Confirm on chain
instead:

```bash
cast code $LOCK --rpc-url fuse | head -c 20      # non-empty == deployed
cast call $LOCK "owner()(address)" --rpc-url fuse
```

`cast call`, `cast send` and `eth_getLogs` are unaffected; it is only the block
header parse. `--resume` hits the same wall, so treat the on-chain read as the
source of truth and record the addresses by hand.

---

## D. When a role grant does not take

Run both confirmations and read them together — they say different things:

| | means |
| --- | --- |
| `doesUserHaveRole` false | the `setUserRole` transaction did not land: wrong authority, or it reverted because you are not that authority's owner |
| `doesUserHaveRole` true, `canCall` false | the `setRoleCapability` transaction did not land, or it named a different target or selector |
| both true, the call still reverts | the target does not have that function — go back to the bytecode check in 10a |

A `cast call` against an *unset* shell variable fails loudly rather than
returning `false`, so a clean `false` means the reads worked and the grants are
what is missing.

Also check you are asking the right authority. `canCall` on an authority the
contract does not consult answers about a world the contract cannot see:

```bash
cast call $LOCK   "authority()(address)" --rpc-url fuse   # must equal the $AUTH you granted on
cast call $MODULE "authority()(address)" --rpc-url fuse
```

> **`encode length mismatch: expected N types, got N-1` means a shell variable
> was empty, not that the signature is wrong.** An unset `$ZAP_ROLE` expands to
> nothing and `cast` simply sees one argument fewer — `expected 4 types, got 3`
> on `setRoleCapability`, `expected 3 types, got 2` on `setUserRole`. `set -u`
> makes the shell fail loudly instead, and quoting every `"$VAR"` stops an empty
> one from vanishing silently. Both are in the command blocks above.

### Signing options, and one thing `cast` does not do

`--account` (a keystore name) is the best of the three: nothing is prompted,
pasted, or left in the environment.

```bash
cast wallet import solid-qa --interactive     # once; asks for the key and a password
cast send --account solid-qa "$MODULE" "setAuthority(address)" "$AUTH" --rpc-url fuse
```

`-i/--interactive` prompts for the key per command and echoes nothing, which is
fine for one transaction. `--private-key "$PRIVATE_KEY"` works too and is what
most examples show — but note that `cast` has **no environment fallback for the
raw key**: unlike `--account` (`ETH_KEYSTORE_ACCOUNT`) and `--rpc-url`
(`ETH_RPC_URL`), omitting `--private-key` does *not* make it read
`$PRIVATE_KEY`.

Do not reach for a bare `read -rs PRIVATE_KEY`: with `-s` and no prompt string
it echoes nothing and prints nothing, so a terminal waiting for input is
indistinguishable from one that has hung. If you want that shape, give it a
prompt: `read -rsp 'key: ' PRIVATE_KEY; echo`.

---

## E. Order of merging across the four repos

The repos depend on each other in one direction only:

```
boring-vault #8  →  solid-backend #1814  →  solid-management-portal #60  →  solid-ui #2523
```

- **boring-vault** first. Nothing builds against it, but the addresses in step
  12 come from it.
- **solid-backend** next. It serves the addresses and the membership state
  everything else reads. Safe to merge and deploy immediately — with the
  addresses empty and both switches off, behaviour is identical to today.
- **solid-management-portal** third. It `PATCH`es
  `/rewards-config/tier-membership`, an endpoint that only exists on the new
  backend. Merging it earlier gives admins a form that 404s.
- **solid-ui** last. It renders whatever the backend says is available, so it is
  inert until the backend is configured.

The portal and the app do not depend on each other, but doing the portal first
means you can configure and check the switches before any user can see a route.

---

## F. Known addresses

Checksummed (EIP-55). `cast` rejects a wrongly-cased address outright, so copy
these rather than retyping.

### Common to both environments

| | |
| --- | --- |
| USDC.e (6 dp) | `0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9` |
| `charge(address,bytes32,uint256)` | `0x1e1d709a` |
| `lockFor(address,uint256)` | `0x3d96e276` |

### Production

| | |
| --- | --- |
| Owner Safe | `0xBA308f2919aa20fbD58fc7406451077fe32F1F29` |
| `FuseRolesAuthority` (owned by that Safe) | `0x058CA721e21492ad72979f9Fb52410f6DA588800` |
| soFUSE vault | `0xb33c8F0b0816fd147FCF896C594a3ef408845e2C` |
| its accountant | `0xb29B5F760d38587f7F4C896C458B9EEB5CAd9C0C` |
| Revenue wallet | `0x845703b9ffAdfbEBaDc6a9E23E1DDe39Fdec6A6b` |

Roles 1, 2 and 3 are taken on the prod authority (cash module, card manager).
Role 4 is the biller, role 5 the zap.

### QA

| | |
| --- | --- |
| `FuseRolesAuthority` (owned by the QA owner EOA) | `0x35d231ad40bFab54b8aCAec3E4Ef4A6A0682246b` |
| soFUSE vault | `0xDA737B0C12a08D85C973F10f25459F07F2BB2882` |
| its accountant | `0xc864e169a1d40b957170E6c848BbcE49f28b361B` |
| `SolidTierLock` | `0x0920Ec78A89Ff18B83Fab0adb16166b726Dd0162` |
| `SolidTierLockZap` | `0xF2D88aC213F431d666c4AF988Bc64AbC2A949b4e` |
| the Teller the zap deposits through | `0x1f8D6492F324916465B1E216a3061B69aa631C94` |

The QA authority is **not** the production one and is owned by a different
account. Role 4 is in use on it (a biller); role 5 holds `lockFor` for the zap
above.

Re-read rather than trust this table if time has passed:

```bash
cast call $LOCK "authority()(address)" --rpc-url fuse
cast call $ZAP  "lock()(address)"      --rpc-url fuse
cast call $ZAP  "teller()(address)"    --rpc-url fuse
```
