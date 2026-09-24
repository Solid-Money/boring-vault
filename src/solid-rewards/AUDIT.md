# AuditAgent scan `02a32335`, triaged

Developer scan of `src/solid-rewards/`, 21 September 2026. 12 findings: 3 High,
8 Low, 1 Info.

**Three were acted on. Nine were not, and this file says why for each** — a
finding dismissed without a reason on the record is one that gets re-raised by
the next scan and re-argued from scratch.

Two of the three High findings are false positives from static analysis that
does not model constructors or read the contract it is flagging. The one real
issue in the report is rated Low.

| # | Finding | Severity | Verdict |
| --- | --- | --- | --- |
| 1 | Uninitialized state variable `accountLocks` | High | Not a defect — a mapping cannot be initialized |
| 2 | Zap locks Ether with no withdrawal | High | Not a defect — `rescueNative` exists, and the report names it in #5 |
| 3 | Reentrancy: state change after external call | High | Not a defect — both calls are in constructors |
| 4 | Teller share-lock period unvalidated | Low | **Fixed** |
| 5 | Centralization risk | Low | Accepted and documented |
| 6 | Solmate `SafeTransferLib` does not check for code | Low | **Fixed** for the one caller-supplied address |
| 7 | Costly operation (SSTORE) inside a loop | Low | Accepted — bounded at 64 |
| 8 | Uninitialized local `closed` | Low | Not a defect — zero is the intended start |
| 9 | Unsafe ERC-20 operation in the module | Low | Not a defect — settlement is measured |
| 10 | Unchecked return from `lockFor` | Low | Not a defect — the return is an index |
| 11 | Deprecated `safeApprove` | Low | **Hardened**, though misattributed |
| 12 | `charge` cyclomatic complexity 13 | Info | Accepted |

---

## Fixed

### 4 — The Teller's share-lock period was never checked

The one finding in the report that describes something real.

A Teller with a non-zero `shareLockPeriod` stamps an unlock time on whoever it
mints to and blocks every transfer out of that address until it passes. The zap
mints to itself and hands the shares to the lock in the same call, so any
non-zero period makes every minting path revert — from inside
`SolidTierLock._lock`, as `TRANSFER_FROM_FAILED`, which says nothing about the
cause. Nothing is lost (the transaction is atomic), but the route is dead and
the error does not explain it.

It was documented as a manual pre-flight step in `DEPLOYMENT.md` and enforced
nowhere.

Now: `ITeller` exposes `shareLockPeriod()`, the constructor refuses a Teller
that has one, and `zapAndLock` re-reads it on each minting call — because the
Teller's owner can set it after the zap is deployed, which is exactly the case
the finding raises. It reverts with `SolidTierLockZap__ShareLockActive(period)`.

The share-token passthrough path is deliberately **not** gated: it mints
nothing, so no unlock time is stamped on the zap and the onward transfer is
unaffected. Blocking it would remove the one route that still works.

### 6 — A caller-supplied asset address was never checked for code

Solmate's `SafeTransferLib` reads a call to a codeless address as a success
with no return data. In `zapAndLock`, `asset` is the one address the caller
chooses, so `safeTransferFrom` and `safeApprove` would both "succeed" against
nothing and the failure would surface from inside the Teller.

Nothing could be stolen this way — the Teller decides what it accepts, and an
unsupported asset reverts there — but the error was misleading. `zapAndLock`
now rejects a codeless `asset` up front.

The rest of the finding does not apply: every other address these contracts
hand to `SafeTransferLib` is constructor configuration, and all three
constructors already reject `code.length == 0`.

### 11 — Approval hygiene

The finding is misattributed: this is solmate's `safeApprove`, not
OpenZeppelin's, and solmate has not deprecated it.

There is a narrower real point underneath it. Both spenders consume the whole
allowance in the same call, so it is back to zero by the next one — but that is
a property of today's callees, not of the code. A deposit asset whose vault
took less than it was offered would leave a remainder, and a token of the
approve-from-zero-only school would then reject every later zap.

`_approveExactly` now clears a non-zero allowance before setting a new one. One
`SLOAD` in the common case, where it finds zero and does nothing.

---

## Not defects

### 1 — "Uninitialized state variable `accountLocks`" (High)

`accountLocks` is a `mapping`. Solidity mappings have no initializer and cannot
have one; every key reads as the zero value until written. "Never explicitly
initialized" is true of every mapping in every Solidity contract ever compiled.

The finding's own reasoning — that the functions reading it "operate on an
empty/default structure unless entries are created through prior execution" —
is a description of how mappings work, not of a defect. No logic here assumes
preconfigured lock data; `_lock` creates the entries.

### 2 — "Contract locks Ether without a withdraw function" (High)

`SolidTierLockZap.rescueNative(address to, uint256 amount)` is a withdrawal
function. Finding #5 in the same report names it as a centralization risk, so
the report both claims it does not exist and flags it for existing.

The `receive()` is there for a wrapper unwrapping to this address; `zapAndLock`
retains no native value.

### 3 — "Reentrancy: state change after external call" (High)

Both flagged calls are in **constructors**:

- `SolidTierLock`: `10 ** BoringVault(payable(_lockToken)).decimals()`
- `SolidTierLockZap`: `SolidTierLock(_lock).lockToken()`

A constructor has no deployed state to re-enter and no prior state to corrupt,
and both addresses are owner-supplied deployment configuration that the same
constructor has already checked for code. A deployer who passes a malicious
lock token has not found a reentrancy path; they have deployed the wrong
contract.

`zapAndLock`, the one function that does make external calls against state, is
already `nonReentrant`, and `SolidTierLock._lock` and `_withdrawFor` likewise.

### 8 — "Uninitialized local variable `closed`" (Low)

`uint256 closed;` is a counter that starts at zero because it has counted
nothing yet. Writing `= 0` would change no behaviour and no bytecode.

### 9 — "Unsafe ERC-20 operation" in `SolidSubscriptionModule` (Low)

The finding says the module "relies directly on the token's `transfer`
behavior" and that a missing or false return "may leave the module's accounting
out of sync with the actual token transfer result".

It does not. `charge` measures the treasury's balance across the call and
reverts if it did not rise by at least `amount`:

```solidity
uint256 treasuryBefore = billingToken.balanceOf(revenueTreasury);
bool ok = ISafe(safe).execTransactionFromModule(...);
if (!ok) revert SolidSubscriptionModule__TransferFailed(safe);
uint256 received = billingToken.balanceOf(revenueTreasury) - treasuryBefore;
if (received < amount) revert SolidSubscriptionModule__NotSettled(safe, amount, received);
```

That check exists precisely for the case the finding describes, and for a
second one it does not mention: `ok` is the success of the Safe *call*, not of
the transfer, so a contract impersonating a Safe could return `true` and move
nothing. The balance delta answers both. This is invariant 7.

A safe-ERC20 wrapper could not be used here in any case — the module does not
make the call, the Safe does, through `execTransactionFromModule`.

### 10 — "Unchecked return" from `lockFor` (Low)

`lockFor` returns the new lock's index in the account's list. The zap has no
use for it; the outcome it cares about is that the call did not revert. There
is no status in the return value to check.

### 5, 7, 12 — Accepted

**5, centralization.** The privileged functions are what an operator needs and
are bounded by design: `rescue` subtracts `totalLockedShares` before
transferring, so no owner value reaches a user's position; `pause` gates new
locks and never withdrawals; `revenueTreasury` and `billingToken` are
immutable. Ownership belongs to the Safe multisig — see `DEPLOYMENT.md` §0 and
the "What the owner cannot do" table.

**7, SSTORE in a loop.** `accountLocks[account].length <= MAX_LOCKS_PER_ACCOUNT`
(64) always holds, enforced in `_lock`, which is invariant 13 and the reason
the cap exists. The loop is bounded and cannot be grown by anyone.

**12, complexity.** `charge` is a sequence of independent guards — paused,
registered, cancelled, per-Safe paused, mandate, ceiling, period, module
enabled — each with its own named error. Collapsing them would cost the
diagnosis, which is what makes a failed charge supportable.
