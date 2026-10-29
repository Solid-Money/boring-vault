# Solid usage billing — the AI API's billing module

One contract, `SolidUsageBillingModule`, on **Base (8453)**. It is the Safe
module the AI API charges usage through: the user signs once, and the
backend's biller takes usage from the Wallet as it accrues, a few dollars at a
time — **USDC first, then soUSD** — into the revenue treasury, never more in a
period than the user agreed to.

## Why not `SolidSubscriptionModule`

It is the same design, and every bound it enforces but one is kept: an
immutable treasury, a mandate only the Safe can write, a single-use
`billingId`, a cap on what one period can take, an org-wide ceiling, global
and per-Safe pauses, settlement measured at the treasury, and consent
withdrawable by `cancel()` or `disableModule`. Four things it could not do for
this job:

| | `SolidSubscriptionModule` | `SolidUsageBillingModule` |
| --- | --- | --- |
| Shortest period | `MIN_PERIOD = 7 days`, a constant | `minPeriod`, set once in the constructor (≥ 1 day) |
| What is drawn | one `billingToken`, immutable | an ordered list of tokens, the owner's to change |
| Unit of the mandate | that token's units | micro-USD (6 decimals) |
| Charges per period | one | any number, together at most the mandate |

A daily cap needs a period under a week, which the subscription module
refuses in `subscribe`. Drawing USDC and then soUSD needs more than one token,
and adding a token later should not need a redeploy or a new signature from
every user.

The last row is the one that matters for money. Solid pays the AI gateway up
front, so whatever usage is owed but not yet collected is Solid's to lose if a
Wallet is emptied, or the mandate cancelled, before the charge. One charge a
period would leave a whole day exposed. Here the backend charges every few
dollars, and the mandate still bounds the day: a period starts at its first
charge, everything charged until it ends counts against `maxAmountPerPeriod`,
and a charge that does not fit reverts `TooSoon(periodEndsAt)` (`canCharge`:
`too soon`). `allowanceOf(safe)` says what is left and when the period ends.

## How a charge is drawn

`charge(safe, billingId, amount)` takes `amount` in micro-USD. The module walks
its billing tokens in order and takes each in full before the next until the
amount is covered. Each token is priced by its `rateProvider`:

- the zero address means a dollar at par — USDC;
- anything else answers `getRate()` with the dollar value, in micro-USD, of one
  whole token. A BoringVault share names its accountant, so soUSD is billed at
  its share price (around $1.07).

Units round up, so the treasury never settles less than the charge. If
everything the Safe holds of the billing tokens cannot cover the amount,
nothing moves and `canCharge` says `insufficient balance`. A token whose rate
provider stops answering is skipped rather than guessed at.

`quote(safe, amount)` returns the draw a charge would make, and
`billableBalanceOf(safe)` what the Safe holds of the billing tokens in dollars.
The backend shows the second as "Wallet" on the AI API screen.

## One signature

The app batches `Safe.enableModule(module)` and `module.subscribe(cap, period)`
into one user operation, so it takes one passkey prompt. That covers every
billing token, including any added later. The module moves tokens with
`execTransactionFromModule`, so no ERC-20 approval is involved. A raise is
`subscribe` again with a bigger cap, which is also one prompt.

## What the owner holds

The owner (the Base multisig) chooses which tokens can be drawn and how each is
priced, and can pause, throttle (`setMaxChargeAmount`) or hold one Safe. It
**cannot** redirect the money (`revenueTreasury` is immutable), charge more
dollars than a user's own mandate, or charge more often than the user agreed.
A wrong rate provider would over-price a token, so every token change is an
event and should be treated like a price-feed change: reviewed by the
multisig's signers.

## Deploying

[DEPLOYMENT.md](./DEPLOYMENT.md) is the runbook, for QA and for production.

## Tests

```bash
forge test --match-path "test/SolidUsageBillingModule.t.sol" --skip "script/*"
```

41 tests, no fork, including a fuzz test that `canCharge` agrees with `charge`
and one that every charge settles at least its amount within the mandate.
