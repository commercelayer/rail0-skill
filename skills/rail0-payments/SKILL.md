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
plus the closed states `voided`, `released`, `refunded`. (`partially_refunded` is
legacy on older gateways — a partial refund no longer changes status.) Two on-chain
balances decide what's legal next: **`capturable_amount`** (escrow, set by
authorize) and **`refundable_amount`** (payee-held, set by capture/charge).

| Op | Signer | Legal when | Outcome |
|----|--------|-----------|---------|
| authorize | payee | from `signed` | escrow funded → `authorized` |
| charge | payee | from `signed`, `mode=charge` | funds to payee → `charged` |
| capture | payee | `capturable_amount > 0`, before `authorization_expiry` | drains escrow → `captured`, else `partially_captured` |
| void | payee | nothing captured yet (`capturable_amount == amount`) | full escrow returned → `voided`; after any capture it reverts `AlreadyCaptured` |
| release | payer or payee | after `authorization_expiry`, `capturable_amount > 0` | uncaptured escrow returned; `released` only on a total release (untouched auth), else status unchanged |
| refund | payee | `refundable_amount > 0`, before `refund_expiry` | funds returned; `refunded` only when fully settled, else status unchanged |
| dispute / close | payer | `refundable_amount > 0`, within refund window | signal only — no funds move |

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

3. **The payee must be logged in for merchant operations.** The gateway gates
   `authorize`, `capture`, `charge`, `void`, and `refund` behind the **payee's
   JWT** (their prepare/submit endpoints are payee-authenticated). So **log in as
   the payee first**: `rail0 auth login -p @payee` (the same key sources as any
   signing command — a keychain `@name`, a raw `0x…` hex key, or the
   `RAIL0_PRIVATE_KEY` env var). `create` (payer-signed), `release` and `dispute`
   (payer, gated on-chain) need no session; `payments list`/`history` do. Reading
   one payment by its **UUID** needs no session.

   `rail0 auth status` only decodes the cached token locally, so it can look valid
   while the gateway rejects it: a token is accepted only by the gateway whose JWT
   secret signed it. Point the CLI at a different gateway (staging vs local), or
   reuse a token minted under a different `JWT_SECRET`, and authed calls `401`
   despite a healthy-looking status. On a surprising `401 not authorized`, just log
   in again against the gateway you're targeting.

## The core pattern: act, then poll

Every lifecycle command is atomic (prepare + sign + broadcast). After it returns,
poll `payments get` until the payment reaches the expected status, so you don't
race the chain. Define this `wait_for` helper once and reuse it in the recipes
below — it returns as soon as the status matches, and surfaces a failed broadcast
instead of hanging:

```sh
# wait_for <id> <expected-status> [timeout-secs]; needs jq. Self-contained — paste
# it once and reuse it in the recipes below.
wait_for() {
  local id=$1 want=$2 t=${3:-120} s j
  for ((i=0; i<t; i+=2)); do
    j=$(rail0 payments get "$id" --json 2>/dev/null)
    s=$(jq -r '.status // empty' <<<"$j")
    [ "$s" = "$want" ] && { echo "✓ $id → $s"; return 0; }
    if [ "$(jq -r '(.transactions // []) | last | .status // empty' <<<"$j")" = failed ]; then
      echo "✗ $id: last tx failed — $(jq -r '(.transactions // []) | last | (.error_message // .error_reason // .error_code // "reverted")' <<<"$j")" >&2
      return 1
    fi
    sleep 2
  done
  echo "✗ $id: timed out waiting for '$want' (now: ${s:-unknown})" >&2; return 1
}
```

Always machine-read with `--json` (never scrape the pretty output) and extract
fields with `jq`, e.g. `jq -r .id`, `.rail0_id`, `.status`, `.capturable_amount`,
`.refundable_amount`.

Capture the payment's **UUID `id`** from the `create` output and reuse it as the
handle for every later command — it addresses the payment with or without a
session. The `rail0_id` also works as a handle, but resolving a bare `rail0_id`
needs a logged-in session on current gateways, so the UUID is the safer default.

## Recipes

Addresses/keys below are placeholders. `-c 5042002` is Arc testnet; discover
chains and tokens with `rail0 chains` / `rail0 tokens`. The merchant (payee) ops
below assume the payee has logged in once (`rail0 auth login -p @payee`, see
Setup); `create`, `release`, and `dispute` don't need a session. `$PID` is the
payment's UUID `id` captured from `create`.

### Authorize → capture (the escrow flow)

```sh
# 1) Payer creates + signs the payment (mode defaults to authorize)
PID=$(rail0 payments create \
  -F <payer_addr> -T <payee_addr> -t USDC -a 10.00 -c 5042002 \
  -p @payer --json | jq -r .id)

# 2) Payee authorizes → funds into escrow; wait until it lands
rail0 payments authorize "$PID" -p @payee
wait_for "$PID" authorized

# 3) Payee captures — full, or partial (repeat for the rest)
rail0 payments capture "$PID" -a 4.00 -p @payee
wait_for "$PID" partially_captured   # 6.00 still in escrow
rail0 payments capture "$PID" -a 6.00 -p @payee
wait_for "$PID" captured
```

A capture that drains the escrow lands in `captured`; one that leaves a balance
lands in `partially_captured`. Never capture more than `capturable_amount`.

### Charge (one-shot, no escrow)

```sh
PID=$(rail0 payments create \
  -F <payer_addr> -T <payee_addr> -t USDC -a 10.00 -c 5042002 -m charge \
  -p @payer --json | jq -r .id)
rail0 payments charge "$PID" -p @payee
wait_for "$PID" charged
```

### Void — cancel an untouched authorization

Only the payee, and **only while nothing has been captured** (the contract reverts
`AlreadyCaptured` otherwise — use `release` for the remainder after a partial
capture). Returns the full escrow to the payer.

```sh
rail0 payments void "$PID" -p @payee
wait_for "$PID" voided
```

### Release — return the uncaptured escrow after expiry

Permissionless (payer or payee; the caller is derived from the signing key), valid
only after `authorization_expiry`. Closes the payment as `released` **only** on a
total release (an untouched authorization); with a captured residual it returns the
uncaptured escrow but leaves the status unchanged so the residual stays refundable.

```sh
rail0 payments release "$PID" -p @payer
rail0 payments get "$PID"   # released (total) or unchanged (residual remains)
```

### Refund — return captured funds to the payer

Payee-signed, partial or full, up to `refundable_amount`. Closes as `refunded`
**only when fully settled** (both escrow and refundable drained); a partial refund
leaves the status unchanged.

```sh
rail0 payments refund "$PID" -a 3.00 -p @payee
wait_for "$PID" refunded   # only if this fully settles it
```

### Dispute / close dispute

Payer-only, signal-only (moves no money), on funds the merchant holds
(`refundable_amount > 0`), within the refund window.

```sh
rail0 payments dispute "$PID" -p @payer --reason 0x<bytes32>
rail0 payments dispute close "$PID" -p @payer
```

## Inspecting state & choosing the next step

- `rail0 payments get <id> --json` — status + live `capturable_amount` /
  `refundable_amount` + `authorization_expiry` / `refund_expiry` + transactions.
- `rail0 payments transactions <id>` — the on-chain attempts (gas, block, status).
- `rail0 payments list` / `payments history <id>` — need `auth login`.

Decide the next legal operation from the **balances and status**, not from
assumptions — see the **Lifecycle & guards** table above.

## Handling failures

- **`422 invalid_state`** — the op isn't legal from the current state (e.g. `void`
  after a capture → `already_captured`/`AlreadyCaptured`; capture/refund above the
  residual → `amount_exceeds_capturable`/`amount_exceeds_refundable`). Re-read
  `payments get` and pick a legal op; don't retry blindly.
- **A broadcast that reverts on-chain** — the transaction lands `failed` with a
  decoded error; the payment stays in its prior state. `wait_for` surfaces this
  instead of spinning. Read `payments transactions <id>` for the reason before
  retrying.
- **Timeouts** — confirmation is a few seconds on testnet but can lag; widen the
  poll timeout rather than assuming failure, and confirm with `payments get`.

## Safety

- Never print, log, or transmit a private key. Pass it via `@name`/env, not inline.
- Captures, charges, and refunds move **real funds** (real value on mainnet, test
  funds on a testnet). On mainnet, confirm the amount, token, chain, and
  payer/payee with the user before broadcasting an irreversible operation.

## Command reference

This SKILL.md is self-contained — the recipes and the **Lifecycle & guards** table
cover every operation. For exhaustive flags/defaults, run `rail0 <command> --help`,
or see the bundled references (present next to this file when installed):
[`references/commands.md`](https://github.com/commercelayer/rail0-skill/blob/main/skills/rail0-payments/references/commands.md)
and [`references/lifecycle.md`](https://github.com/commercelayer/rail0-skill/blob/main/skills/rail0-payments/references/lifecycle.md).
