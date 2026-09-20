# Solid rewards v3 — tier upgrade contracts

Two contracts back the v3 membership tiers. Points no longer buy a tier; a user
holds Prime or Ultra by **locking FUSE** or by **paying an annual fee in USDC**.

| Contract | What it is | Who calls it |
| --- | --- | --- |
| `SolidTierLock` | Fixed-term escrow for soFUSE shares | the user's Safe (`lock`), anyone (`withdrawFor`) |
| `SolidSubscriptionModule` | Safe module that collects the annual fee | the user's Safe (`subscribe`/`cancel`), the biller (`charge`) |

## Why the lock is an escrow rather than a lock in place

Keeping the shares in the user's own Safe and merely forbidding their movement
would be better, and on this stack it cannot be enforced:

- **A Safe transaction guard is not consulted for module transactions on Safe
  1.4.1** — `ModuleManager.execTransactionFromModule` calls no guard, and module
  guards only arrived in 1.5.0. Solid's accounts are `toSafeSmartAccount` v1.4.1
  behind EntryPoint 0.7, so *every* user operation goes through the 4337 module.
  A guard would be bypassed by the ordinary path, not by an exotic one.
- **`BoringVault`'s `beforeTransfer` hook cannot see an amount.** Its signature is
  `beforeTransfer(from, to, operator) view`, so it can refuse a holder's every
  transfer or none of them — never the locked part of a balance. And
  `TellerWithMultiAssetSupport.bulkWithdraw` redeems through `vault.exit`, which
  burns without calling the hook at all.

`safe-fndn/safe-locking` was evaluated and rejected: it is itself a custodial
escrow (so it solves none of the above), its unlock is a cooldown rather than a
fixed term, it is written against a single named token, its last commit is May
2024, and it targets solc 0.8.23 whose default EVM is shanghai — this repo pins
`evm_version = 'london'`.

So the commitment is held in `SolidTierLock`, and the design pays for that with
two structural guarantees rather than promises:

1. **No path sends shares anywhere but back to the account that locked them.**
   There is no admin transfer and no sweep; `rescue` is arithmetically barred
   from `totalLockedShares`. A compromised owner key can stop new locks and
   nothing else.
2. **Withdrawal is permissionless once the term is up**, which is what makes
   "your FUSE unlocks automatically" true — a backend cron returns matured
   positions, and since the destination is fixed to the owner, nobody gains by
   calling it.

Terms are snapshotted per lock, so changing `lockDuration` cannot reach back and
extend a commitment a user has already made.

## Why the subscription is a module rather than an allowance

An ERC-20 approval's only bound is its amount: infinite is an unrevocable
licence in practice, and finite means re-signing every year — the interaction a
subscription exists to remove.

`SolidSubscriptionModule` moves the bounds on-chain. Note what is **not** a
parameter of `charge`:

- the **destination** (`revenueTreasury`, immutable, no setter),
- the **asset** (`billingToken`, immutable, no setter).

The biller role chooses only the Safe and the amount. Everything else is fixed
by the contract and by the user's own mandate: their cap per charge, their
minimum gap between charges, a single-use `billingId`, an org-wide ceiling that
binds existing mandates when lowered, a global pause and a per-Safe pause.

Consent is withdrawable two ways — `cancel()` here, or `disableModule` on the
Safe, which the Safe itself enforces on the next block. `lastChargedAt` survives
a cancel/re-subscribe cycle, so that round trip cannot be used to be billed
twice in one year.

`SolidCashModule` was considered and is the wrong tool: it has no destination
parameter (it pays only its own settlement treasury), and billing the annual fee
through it would consume the cardholder's daily and monthly *card* spending
limits.

## Deploying

```
OWNER=0x… SOFUSE_VAULT=0x… SOFUSE_ACCOUNTANT=0x… USDC=0x… REVENUE_TREASURY=0x… \
LOCK_DURATION_SECONDS=31536000 MIN_LOCK_SHARES=1000000000000000000 MAX_CHARGE_AMOUNT=500000000 \
forge script script/DeploySolidRewards.s.sol --rpc-url fuse --broadcast
```

Then, as the owner: attach the `FuseRolesAuthority`, give the biller role
`charge`, and grant it to the billing account. Until that is done, only the
owner can charge anything.

The billing account is the backend's own ERC-4337 smart account — the address
`AAOperationsService` logs at boot as "Smart Account ready on chain 122: 0x…" —
and **not** the EOA that owns it, and never a user's Safe. The backend submits
the charge as a UserOperation, so `msg.sender` inside `charge` is that account;
the EOA only signs the operation and never appears as the caller. Granting the
role to the EOA would leave every charge reverting on `requiresAuth`.

A user's Safe is the wrong grantee for a different reason: the biller chooses
which Safe is charged, so a Safe holding that role could charge any other
subscriber. The Safe's side of this is its own mandate, set by `subscribe`, and
nothing more.

**[DEPLOYMENT.md](./DEPLOYMENT.md) is the full runbook** — toolchain, the
pre-flight checks that matter because three constructor arguments are immutable,
the exact role-grant transactions, the backend and app-config wiring, the order
the four repos go out in, and the kill switches.

## Ownership

Both contracts are `solmate/Auth`, constructed as `Auth(OWNER, Authority(0))`:
owned, not permissionless, and not ownerless. `OWNER` should be the Safe
multisig — the deployer EOA holds nothing once the constructor has run.

The owner can retune (`lockDuration`, `minLockShares`, `maxChargeAmount`), pause,
and rescue stray tokens. The owner **cannot** take a locked position (`rescue`
is barred from `totalLockedShares`), extend a lock already taken (each lock
snapshots its own `unlocksAt`), block a withdrawal (`pause` gates `lock` only),
redirect the money or change the billed asset (both immutable), or bill outside
a user's own mandate.

`lock`, `withdraw`, every view, and `subscribe`/`cancel`/`resume` need no
permission — a Safe can only ever speak for itself. `withdrawFor(account)` is
deliberately callable by anyone, and always pays `account` rather than the
caller, so a keeper can return a matured position without the user coming back.

## Audit response

Scan `7e23ee04-559a-4442-9245-cd29c935e790` (AuditAgent, developer scan).

**Fixed:**

- **A counterfeit Safe could fake settlement** (their Medium, and the only
  exploitable finding). Everything `charge` read came from the address being
  charged — `isModuleEnabled`, and the boolean from
  `execTransactionFromModule`. A contract returning `true` from both and
  forwarding nothing collected a `Charged` receipt and burned a billing id
  having paid nothing. `charge` now measures the treasury's balance across the
  call and reverts with `NotSettled` unless the money actually arrived. The same
  line covers their "unsafe ERC20 operation" finding: a token that returns
  `false` instead of reverting also leaves `ok` true.
- **`lock` truncated oversized deposits.** `uint128(shares)` is an explicit
  downcast, which does not revert, so a deposit above 2^128 would be pulled and
  counted in full by the uint256 totals while the position recorded the
  remainder. Unreachable at any real supply; now a check, because the property
  should hold for whatever token this is pointed at.
- **`lock` trusted a return value as an amount.** A fee-on-transfer or rebasing
  token reports success having delivered less, leaving `totalLockedShares`
  claiming more than the contract holds. The balance is now measured either side
  of the pull.
- **Constructors accepted addresses with nothing behind them.** Neither the
  module's treasury and token nor the lock's accountant has a setter, so a zero
  or codeless value was unfixable after deployment. Rejected at construction.
- `maturedSharesOf` is `external`; the two view loops initialise `i` explicitly.

**Not fixed, with reasons:**

- *"`accountLocks` is uninitialized"* (their High) — a mapping. Solidity has no
  way to "initialize" one and no way to read an uninitialized one; every key
  reads as an empty array. Scanner false positive.
- *"Reentrancy: state change after external call"* (their High) — the call is
  `decimals()` on the share token, in the **constructor**, on an address the
  deployer chose. There is no state to corrupt, no funds present, and no
  attacker-supplied address. The real risk in the neighbourhood — a lock token
  that is not a token at all — is the constructor check added above.
- *"Costly operations inside loop"* — bounded by `MAX_LOCKS_PER_ACCOUNT = 64`,
  which exists for this reason. A user cannot grow their own list past it.
- *"Solmate's SafeTransferLib does not check for code"* — true of the library,
  moot here: the constructor now rejects a codeless token, and `decimals()`
  already reverted on one.
- *"Centralization risk"* — accurate, and the point of the **Ownership** section
  above. What matters is not that an owner exists but what it cannot reach, and
  the tests pin that.
- *"High function complexity"* (`charge`, cyclomatic 12) — the branches are the
  mandate checks, and each one is a distinct named revert a support engineer
  reads. The real risk in it is that `charge` and `canCharge` state the same
  conditions twice and could drift, so that agreement is now a fuzz test rather
  than a convention.

The 15 invariants supplied with that scan are all pinned by tests, including the
two that were not previously enforced: a lock fitting its `uint128` record
(invariant 3) and lock accounting reflecting shares actually received
(invariant 4).

## Tests

```
forge test --match-path "test/Solid*.t.sol"
```

58 tests, no fork required.
