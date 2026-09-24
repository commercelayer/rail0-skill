# rail0 CLI — command reference

Exact flags and arguments for the commands this skill uses. Run
`rail0 <command> --help` for the authoritative inline help.

## Global

- `--base-url <url>` / `RAIL0_BASE_URL` / `rail0 config set base-url <url>` —
  target gateway (default `https://api.rail0.xyz`). Precedence: flag > env >
  config file > default.
- `--json` — strict JSON output (use this for scripting; also the default when
  piped). `-q/--quiet` — only the result's id (`rail0_id` for a payment,
  `transaction_hash`/`id` otherwise), one per line. `--pretty` — human table/kv view.
  `--debug` — HTTP traces to stderr. Stdout carries only the result; sign-in notices
  and wait progress go to stderr.
- `rail0 health` — gateway liveness. `rail0 chains [--symbol S] [--network-type
  testnet|mainnet]`, `rail0 tokens [--chain-id N] [--symbol S]` — catalog.

## Keys (OS keychain — secrets never leave the machine)

- `rail0 keys` — list saved key names.
- `rail0 keys add <name>` — save a key (hidden prompt; validates + prints the
  derived address).
- `rail0 keys address <name>` — show the address for a saved key.
- `rail0 keys rm <name>` — delete a saved key.
- Reference a saved key on any `--private-key` flag as `@name`.

## Auth

Signing commands sign in as their own `-p` key automatically. Reads use the stored
session, which must belong to the payment's payer or payee.

- `rail0 auth login -p @name|<0xhex>` — SIWE login, caches a JWT (`RAIL0_TOKEN`
  env overrides the cache). Resolves the key like the signing commands: a keychain
  `@name`, a raw `0x` hex key, or the `RAIL0_PRIVATE_KEY` env var.
- `rail0 auth status` — show address / account / expiry. `rail0 auth logout` —
  clear the token.

## Payment id argument

Commands that take a payment id accept **either** the UUID `id` **or** the
`rail0_id` (`0x` + 64 hex); the gateway resolves both. Capture the `rail0_id` from
`create` output (`-q` prints exactly that) and reuse it.

## Lifecycle commands

| Command | Signer | Key flag | Other flags |
| --- | --- | --- | --- |
| `payments create` | payer | `-p/--private-key` | `-F/--from` (payer), `-T/--to` (payee), `-t/--token` (e.g. USDC), `-a/--amount` (decimal), `-c/--chain-id` (numeric), `-C/--charge` (create with mode=charge; **there is no `-m/--mode`**), `-d/--description`, `-f/--payment-file` |
| `payments authorize <id>` | payee | `-p` | — |
| `payments charge <id>` | payee | `-p` | — (payment must have been created with `-C`) |
| `payments capture <id>` | payee | `-p` | `-a/--amount` (decimal, ≤ capturable) **required** |
| `payments void <id>` | payee | `-p` | — |
| `payments release <id>` | payer or payee | `-p` | — |
| `payments refund <id>` | payee | `-p` | `-a/--amount` (decimal, ≤ refundable) **required** |
| `payments dispute <id>` | payer | `-p` | `--reason 0x<bytes32>` (optional) |
| `payments dispute close <id>` | payer | `-p` | `--reason` (optional) |

### Two flags every scripted flow needs

- **`--yes`** — required by `capture`, `charge`, `refund`, `void`, `release`,
  `dispute` and `dispute close` whenever there is no TTY; without it they exit with
  *refusing to run without confirmation in a non-interactive shell*. `create`,
  `authorize` and `sign` do **not** accept it (`unknown flag`).
- **`-w`/`--wait`** — on every lifecycle command; blocks until the operation
  confirms on-chain (or fails). `--timeout` defaults to **15m**, sized for the
  slowest chain's finality.

And one every re-runnable flow needs:

- **`--idempotency-key <key>`** — on `create` and every on-chain operation. A re-run
  with the same key returns the first attempt (the payment, or the operation's
  transaction — followed with `-w` if given) instead of opening a second one. Use it
  whenever a script may re-run a command after a timeout.

All lifecycle commands are atomic (prepare → sign locally → broadcast) and, without
`-w`, return as soon as they have broadcast — the status advances seconds later. Use
`-w` rather than a hand-rolled poll.

- `payments sign <id>` — deposit the payer signature on an already-created payment
  (payer key; no `--yes`). Useful when `create` ran without a key.
- `payments wait <id> [--until <status>] [--timeout 15m]` — block on a payment you
  did not just act on, or on a status rather than one operation.
- `payments redrive <id> <transaction_id> [-w]` — payee; re-broadcast a stuck
  `pending` transaction that reads `redrivable: true` (the gateway already holds its
  signed bytes). No new signature, no `--yes`.

## Read commands

Every read needs a stored session of the payment's payer or payee.

| Command | Notes |
| --- | --- |
| `payments get <id>` | status, balances, expiries, `escrow_stranded`/`escrow_returnable_at`, every transaction |
| `payments transactions <id>` | on-chain attempts; `--operation`, `--status`, `--sort` |
| `payments transaction <id> <transaction_id>` | one attempt: status, decoded revert reason, `redrivable` |
| `payments list` | your payer/payee payments; `--chain-id`, `--disputed`, `--min-amount`/`--max-amount`, `--created-from`/`--created-to` (ISO-8601), `--sort` |
| `payments history <id>` | chronological timeline |
| `payments disputes <id>` | dispute open/close history; `--status open\|closed` |

## Amount formats

- `create` / `capture` / `refund` `--amount`: **decimal** token units (`"10.50"`);
  the gateway converts to base units.
- `payments list` `--min-amount`/`--max-amount`: **base units** (integers).
