# rail0 payment lifecycle — states, guards, and who signs

Read this to compose a correct flow: which operation is legal from which state,
who must sign it, and how the status settles. The gateway mirrors the RAIL0
contract's rules exactly, so a command that violates them fails (`422
invalid_state` at the gateway, or an on-chain revert if it slips through).

## Parties

- **payer** (buyer) — opens the payment (`create`), signs the funding
  authorization, may `release` (after expiry), and `dispute` / close a dispute.
- **payee** (merchant) — `authorize`, `capture`, `charge`, `void`, `refund`, and
  may also `release`.

The signing key you pass (`-p`) determines who the caller is — the contract checks
the recovered signer, so use the right party's key for each op.

## States

| Status | Meaning |
| --- | --- |
| `unsigned` | Created; payer signature not yet stored |
| `signed` | Payer signature stored; awaiting the payee's first action |
| `authorized` | Funds held in escrow; capture/void/release available |
| `charged` | One-shot charge executed; refund available |
| `captured` | Escrow fully captured by the payee |
| `partially_captured` | Some captured; remainder still in escrow (capturable) |
| `voided` | Authorization cancelled before any capture; escrow returned (terminal) |
| `released` | Untouched authorization fully returned to the payer (terminal) |
| `refunded` | Fully settled by refund — escrow and refundable both drained (terminal) |
| `partially_refunded` | **Legacy** — no longer produced; a partial refund now leaves the status unchanged |
| `failed` | A broadcast reverted; the payment stays usable in its prior state |

## Transitions (happy path)

```
unsigned ──create signs──▶ signed
  signed ──authorize (payee)──▶ authorized
  signed ──charge (payee)─────▶ charged
  authorized ──capture x──▶ partially_captured ──capture (drains)──▶ captured
  authorized ──void (payee, nothing captured)──▶ voided
  authorized ──release (after expiry, total)──▶ released
```

A payment only ever leaves its state to **close** (the design privileges the
happy-path status): a partial `capture` moves `authorized → partially_captured`;
a partial `refund`, or a `release`/`refund` that leaves any residual, does **not**
change the status.

## Operation guards (the rules that make ops fail)

- **capture** — from `authorized` / `partially_captured`, `amount` in
  `(0, capturable_amount]`. Drains escrow → `captured`; otherwise
  `partially_captured`.
- **void** — payee only, and **only while nothing has been captured**
  (`capturable_amount == amount`, i.e. status `authorized` untouched). After any
  capture it reverts `AlreadyCaptured` → recover the remainder with `release`.
- **release** — after `authorization_expiry`, payer or payee. Returns the
  uncaptured escrow. Becomes `released` **only** on a total release (untouched
  authorization); with a captured residual the status is unchanged and the
  captured funds stay refundable.
- **refund** — payee only, `amount` in `(0, refundable_amount]`, before
  `refund_expiry`. Becomes `refunded` **only when fully settled** (both buckets
  zero); otherwise the status is unchanged.
- **dispute** — payer only, only while `refundable_amount > 0` and within the
  refund window; signal-only (no funds move). One open dispute at a time. A pure,
  uncaptured authorization is cancelled via `void`, not disputed.
- **dispute close** — payer only; a full refund also auto-closes an open dispute.

## Two independent balances

- `capturable_amount` — funds still in escrow (set by `authorize`, reduced by
  `capture`/`void`/`release`). Drives capture/void/release.
- `refundable_amount` — funds the payee holds that can still be returned (set by
  `capture`/`charge`, reduced by `refund`). Drives refund/dispute.

Always choose the next operation from the current status **and** these balances —
read them from `payments get --json`, don't assume.

## Time windows

- `authorization_expiry` — capture must happen before it; `release` opens after it.
- `refund_expiry` — refund and dispute must happen before it.

The gateway does not block on time by itself (the contract does), so a
time-invalid op fails on-chain (`failed` transaction) rather than at the gateway.
