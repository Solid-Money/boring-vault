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
`charge`, and grant it to the billing signer. Until that is done, only the owner
can charge anything.

## Tests

```
forge test --match-path "test/Solid*.t.sol"
```

49 tests, no fork required.
