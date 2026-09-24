---
name: rail0-payments
description: >-
  Make and manage stablecoin (USDC) payments through the rail0 gateway using the
  `rail0` CLI — the full authorize → capture lifecycle plus charge, void, release,
  refund, and dispute. Use this whenever the user wants to take or make a stablecoin
  payment over rail0, place or capture an authorization hold, charge a buyer
  one-shot, void/release/refund a payment, open or close a dispute, or check a rail0
  payment's on-chain status — even if they don't say "rail0" explicitly but the
  context is the rail0 gateway / escrow / a payment id (a UUID or a 0x…64-hex
  rail0_id). Covers key & signing setup, the prepare→sign→broadcast atomic commands,
  and polling a payment to its settled state.
---

# rail0 payments (via the `rail0` CLI)

Drive the rail0 payment gateway from the command line to move stablecoins with a
card-network-style lifecycle: **authorize** funds into escrow, **capture** them
(fully or in parts) later, or **charge** immediately; then **void**, **release**,
or **refund**; buyers can **dispute**. Every on-chain step is one atomic CLI
command that prepares the transaction, signs it locally, and broadcasts it — the
private key never leaves the machine.

## Mental model (read this first)

A payment is opened by the **payer** (buyer) and acted on by the **payee**
(merchant). Two modes:

- **authorize** — pull funds into escrow now, `capture` later (partial or full).
- **charge** — one-shot: authorize + capture in a single call, no escrow window.

The gateway is asynchronous: a lifecycle command returns immediately (HTTP 202)
after broadcasting; the on-chain result lands a few seconds later and the payment
**status** advances then. So the pattern is always **run the command, then poll
`payments get` until the status settles** (or a transaction fails).

Who signs what, which operation is legal from which state, and the exact status
semantics (e.g. `void` is only allowed before any capture; `refund` closes as
`refunded` only when fully settled) are important and easy to get wrong — see
**Lifecycle & guards** below before composing a flow.

## Lifecycle & guards

States: `unsigned → signed → authorized | charged → captured | partially_captured`,
plus `expired` (an authorization whose window lapsed with nothing captured — the
escrow is **still on-chain**, so it is not closed) and the closed states `voided`,
`released`, `refunded`. (`partially_refunded` is legacy — kept for old rows, no
longer produced: a partial refund does not change status.) Two on-chain balances
decide what's legal next: **`capturable_amount`** (escrow, set by authorize) and
**`refundable_amount`** (payee-held, set by capture/charge).

| Op | Signer | Legal when | Outcome |
|----|--------|-----------|---------|
| authorize | payee | from `signed` | escrow funded → `authorized` |
| charge | payee | from `signed`, created with `-C` | funds to payee → `charged` |
| capture | payee | `capturable_amount > 0`, before `authorization_expiry` | drains escrow → `captured`, else `partially_captured` |
| void | payee | nothing captured yet (`authorized` or `expired`, `capturable_amount == amount`) | full escrow returned → `voided`; after any capture it is refused (`already_captured`) |
| release | payer or payee | after `authorization_expiry`, `capturable_amount > 0` | uncaptured escrow returned; `released` only on a total release (untouched auth), else status unchanged |
| refund | payee | `refundable_amount > 0`, before `refund_expiry` | funds returned; `refunded` only when fully settled, else status unchanged |
| dispute / close | payer | `refundable_amount > 0`, within refund window | signal only — no funds move |

> A **full** refund auto-closes an open dispute. Calling `dispute close` afterwards
> fails with `there is no open dispute to close` — check `disputed` on the payment
> before assuming you still have to close it.

> After a **partial** capture and before `authorization_expiry`, neither `void` (something
> was captured) nor `release` (the window is still open) can return the rest of the
> escrow. The payment says so: `escrow_stranded: true` and `escrow_returnable_at` (when
> `release` opens). Capture the rest, or wait and release.

Always choose the next op from the **current status and these two balances** (read
from `payments get --json`), never from assumptions.

## Setup

1. **The gateway URL.** The CLI defaults to `https://api.rail0.xyz`. Point it
   elsewhere (staging, local) with the `RAIL0_BASE_URL` env var, `--base-url`, or
   `rail0 config set base-url <url>`. Confirm reachability with `rail0 health`.

2. **Signing keys stay local — reference them, never embed them.** Each on-chain
   op needs the caller's secp256k1 private key, resolved (in order) from the
   `--private-key`/`-p`/`--pk` flag or the `RAIL0_PRIVATE_KEY` env var. The key is
   used only to sign locally — it is **never** sent to the gateway. Choose how to
   supply it by where the agent runs:
   - **Interactive / desktop (preferred): the OS keychain.** `rail0 keys add
     <name>` stores the secret encrypted at rest; reference it as `@name` on `-p`
     (works for `auth login` too). It never touches a plaintext file, shell
     history, or an env dump. Each machine runs `keys add` once.
   - **Headless / CI / servers: `RAIL0_PRIVATE_KEY`, injected by a secrets
     manager** (Vault, cloud KMS/Secrets Manager, CI secrets, 1Password CLI). A
     local `.env` is acceptable only if git-ignored and `chmod 600` — never
     committed.
   - **Never** paste a raw `0x…` key inline (`-p 0xabc…` lands in shell history),
     hardcode it in the skill/repo, or commit a `.env`. Raw hex is a last resort
     for a one-off.

3. **Sessions: signing commands sign in by themselves; reads need one.** Every
   `/payments` call is behind a SIWE session, and a payment is readable only by its
   payer or payee. A **signing** command (`create`, `authorize`, `capture`, …) signs
   in as its own `-p` key before it starts — no separate login needed. A **read**
   (`payments get`, `transactions`, `transaction`, `wait`, `list`, `history`,
   `disputes`) uses the stored session, so log in once as one of the parties:
   `rail0 auth login -p @payee` (same key sources as any signing command). A signing
   command also stores its session, unless a session for another address is already
   stored — that one is left in place, and the command's own sign-in serves that
   command only.

   `rail0 auth status` only decodes the cached token locally, so it can look valid
   while the gateway rejects it: a token is accepted only by the gateway whose JWT
   secret signed it. Point the CLI at a different gateway (staging vs local), or
   reuse a token minted under a different `JWT_SECRET`, and authed calls `401`
   despite a healthy-looking status. On a surprising `401 not authorized`, just log
   in again against the gateway you're targeting.

## The core pattern: act with `--wait`, and confirm with `--yes`

Two flags decide whether a scripted flow works at all. Neither is optional for an
agent.

**`--yes` is REQUIRED in a non-interactive shell.** Every fund-moving command —
`capture`, `charge`, `refund`, `void`, `release`, `dispute` (and `dispute close`) —
asks for confirmation, and without a TTY it refuses outright:

```
Error: refusing to run without confirmation in a non-interactive shell; pass --yes to proceed
```

`create`, `authorize` and `sign` do **not** take `--yes`; passing it is an
`unknown flag` error. So: confirm the parameters with the human (see *Safety*),
then pass `--yes` on the six commands that require it.

**`-w`/`--wait` blocks until the operation confirms on-chain**, and every lifecycle
command has it. The gateway is asynchronous — a command returns after broadcasting
and the status advances seconds later — so without `-w` you are racing the chain
and the very next command fails with a `422` for a state that has not arrived yet.

```sh
rail0 payments capture "$PID" -a 4.00 --yes -w   # returns once confirmed, or fails
```

`--timeout` (default **15m**) bounds the wait and is sized for the slowest chain's
finality: a 60-confirmation chain like Base Sepolia takes minutes, not seconds.

When you need to wait on a payment you did not just act on — or wait for a status
rather than one operation — use the built-in:

```sh
rail0 payments wait "$PID"                     # until nothing is in flight
rail0 payments wait "$PID" --until captured    # until a specific status
```

Do **not** hand-roll a polling loop. `-w` and `payments wait` already handle the
confirmed/failed/timeout cases, and a bash helper in this file is worse than
useless: a `$1`/`$2` inside it is substituted with the skill's own invocation
arguments when the skill is called with any, so the helper silently ignores its
parameters.

Always machine-read with `--json` (never scrape the pretty output) and extract
fields with `jq`, e.g. `.status`, `.capturable_amount`, `.refundable_amount`,
`.escrow_stranded`. Stdout carries only the result: sign-in notices and wait
progress go to stderr, so `--json | jq` works as is. For just the handle, `-q`/
`--quiet` prints the payment's `rail0_id` and nothing else.

Capture the handle from `create` (`-q`, or `--json | jq -r .rail0_id`) and reuse it
for every later command. The UUID `id` works just as well: the gateway resolves
either form.

**Re-runs: pass `--idempotency-key`.** A `-w` that times out on a slow chain exits
non-zero while the operation may still be in flight — and re-running a capture
without a key is a **second capture**. Give every fund-moving command a key you
keep (`--idempotency-key "$ORDER-capture-1"`): re-run with the same key and the CLI
follows the original transaction instead of broadcasting another. Without a key,
never re-run after a timeout: `payments wait` / `payments get` first.

## Recipes

Addresses/keys below are placeholders. `-c 5042002` is Arc testnet; discover
chains and tokens with `rail0 chains` / `rail0 tokens`. Each signing command signs
in as its own `-p` key (see Setup); the reads need a stored session of either
party. `$PID` is the payment's `rail0_id` captured from `create` with `-q`.

### Authorize → capture (the escrow flow)

```sh
# 1) Payer creates + signs the payment (mode defaults to authorize); -q prints the rail0_id
PID=$(rail0 payments create \
  -F <payer_addr> -T <payee_addr> -t USDC -a 10.00 -c 5042002 \
  -p @payer -q)

# 2) Payee authorizes → funds into escrow. -w blocks until it confirms.
#    authorize takes NO --yes (passing it is an unknown-flag error).
rail0 payments authorize "$PID" -p @payee -w

# 3) Payee captures — full, or partial (repeat for the rest).
#    capture REQUIRES --yes in a non-interactive shell.
rail0 payments capture "$PID" -a 4.00 -p @payee --yes -w   # → partially_captured
rail0 payments capture "$PID" -a 6.00 -p @payee --yes -w   # → captured
```

A capture that drains the escrow lands in `captured`; one that leaves a balance
lands in `partially_captured`. Never capture more than `capturable_amount`.

### Charge (one-shot, no escrow)

```sh
PID=$(rail0 payments create \
  -F <payer_addr> -T <payee_addr> -t USDC -a 10.00 -c 5042002 -C \
  -p @payer -q)
rail0 payments charge "$PID" -p @payee --yes -w
```

### Void — cancel an untouched authorization

Only the payee, and **only while nothing has been captured** (the contract reverts
`AlreadyCaptured` otherwise — use `release` for the remainder after a partial
capture). Returns the full escrow to the payer.

```sh
rail0 payments void "$PID" -p @payee --yes -w
```

### Release — return the uncaptured escrow after expiry

Permissionless (payer or payee; the caller is derived from the signing key), valid
only after `authorization_expiry`. Closes the payment as `released` **only** on a
total release (an untouched authorization); with a captured residual it returns the
uncaptured escrow but leaves the status unchanged so the residual stays refundable.

```sh
rail0 payments release "$PID" -p @payer --yes -w
rail0 payments get "$PID"   # released (total) or unchanged (residual remains)
```

### Refund — return captured funds to the payer

Payee-signed, partial or full, up to `refundable_amount`. Closes as `refunded`
**only when fully settled** (both escrow and refundable drained); a partial refund
leaves the status unchanged.

```sh
rail0 payments refund "$PID" -a 3.00 -p @payee --yes -w
# status becomes `refunded` only if this fully settles it; a partial leaves it as is
```

### Dispute / close dispute

Payer-only, signal-only (moves no money), on funds the merchant holds
(`refundable_amount > 0`), within the refund window.

```sh
rail0 payments dispute "$PID" -p @payer --reason 0x<bytes32> --yes -w
rail0 payments dispute close "$PID" -p @payer --yes -w
# A full refund already auto-closes an open dispute — check `disputed` first, or
# this fails with `there is no open dispute to close`.
```

## Inspecting state & choosing the next step

All of these need a stored session of the payer or payee (see Setup).

- `rail0 payments get <id> --json` — status + live `capturable_amount` /
  `refundable_amount` + `authorization_expiry` / `refund_expiry` +
  `escrow_stranded` / `escrow_returnable_at` + every transaction.
- `rail0 payments transactions <id>` — the on-chain attempts (gas, block, status).
- `rail0 payments transaction <id> <transaction_id>` — one attempt: its status, the
  decoded revert reason of a failed one, and whether a stuck one is `redrivable`.
- `rail0 payments list` / `payments history <id>` / `payments disputes <id>`.

Decide the next legal operation from the **balances and status**, not from
assumptions — see the **Lifecycle & guards** table above.

## Handling failures

- **`422` state refusals** — the op isn't legal from the current state, and the
  error `code` says why (e.g. `already_captured` for a `void` after a capture,
  `not_capturable`, `amount_exceeds_capturable` / `amount_exceeds_refundable` above
  the residual). Re-read `payments get` and pick a legal op; don't retry blindly.
- **`422` window refusals** — `authorization_expired` (capture after the window:
  the escrow can only be released now), `authorization_not_expired` (release
  before it), `refund_expired` (refund or dispute after the refund window). The
  gateway refuses these **before** anything is broadcast, so no gas is spent.
- **A broadcast that reverts on-chain** — the transaction lands `failed` with a
  decoded error; the payment stays in its prior state. `-w` surfaces that instead
  of returning as if it had worked. Read `payments transaction <id> <tx>` for the
  reason before retrying.
- **A transaction stuck `pending` with `redrivable: true`** — the gateway holds its
  signed bytes but the broadcast was lost. The gateway retries on its own schedule;
  to do it now: `rail0 payments redrive <id> <transaction_id> -w` (payee). A pending
  row **without** `redrivable` was never signed — re-run the operation instead.
- **`unknown flag: --yes`** — you passed it to `create`, `authorize` or `sign`,
  which take no confirmation. Drop it there; keep it on the other six.
- **Timeouts** — `--timeout` defaults to 15m because that covers the slowest
  chain's finality. A 60-confirmation chain (Base Sepolia) takes minutes; raise
  the timeout rather than assuming failure, and confirm with `payments wait` /
  `payments get` — see *Re-runs* above before running the command again.

## Safety — you are moving real money

This skill has **direct money-movement capability**: `authorize`/`capture`/`charge`
pull funds from the payer, `refund`/`void`/`release` return them, and every
operation broadcasts an **irreversible** on-chain transaction. Treat it with a
human in the loop:

- **Confirm before every fund-moving broadcast.** Before `authorize`, `capture`,
  `charge`, or `refund`, restate the **amount, token, chain, and payer/payee** back
  to the user and get explicit approval. Never broadcast a fund-moving operation the
  user did not ask for, and never invent amounts or parties. Mandatory on mainnet;
  on a testnet use judgment.
- **Prefer a testnet** while developing, or whenever the parameters are uncertain.
- **On-chain is final** — there is no undo once a transaction confirms. Double-check
  the amount is within `capturable_amount` / `refundable_amount` first.
- **Never** print, log, or transmit a private key; pass it via `@name`/env, never
  inline (see *Signing keys*). Only signatures and signed transactions go to the
  gateway — never the key.

## Command reference

This SKILL.md is self-contained — the recipes and the **Lifecycle & guards** table
cover every operation. For exhaustive flags/defaults, run `rail0 <command> --help`,
or see the bundled references (present next to this file when installed):
[`references/commands.md`](https://github.com/commercelayer/rail0-skill/blob/main/skills/rail0-payments/references/commands.md)
and [`references/lifecycle.md`](https://github.com/commercelayer/rail0-skill/blob/main/skills/rail0-payments/references/lifecycle.md).
