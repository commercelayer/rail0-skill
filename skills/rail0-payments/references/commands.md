# rail0 CLI — command reference

Exact flags and arguments for the commands this skill uses. Run
`rail0 <command> --help` for the authoritative inline help.

## Global

- `--base-url <url>` / `RAIL0_BASE_URL` / `rail0 config set base-url <url>` —
  target gateway (default `https://api.rail0.xyz`). Precedence: flag > env >
  config file > default.
- `--json` — strict JSON output (use this for scripting; also the default when
  piped). `--pretty` — human table/kv view. `--debug` — HTTP traces to stderr.
- `rail0 health` — gateway liveness. `rail0 chains [--symbol S] [--network-type
  testnet|mainnet]`, `rail0 tokens [--chain-id N] [--symbol S]` — catalog.

## Keys (OS keychain — secrets never leave the machine)

- `rail0 keys` — list saved key names.
- `rail0 keys add <name>` — save a key (hidden prompt; validates + prints the
  derived address).
- `rail0 keys address <name>` — show the address for a saved key.
- `rail0 keys rm <name>` — delete a saved key.
- Reference a saved key on any `--private-key` flag as `@name`.

## Auth (only for account-scoped reads)

- `rail0 auth login -p @name|<0xhex>` — SIWE login, caches a JWT (`RAIL0_TOKEN`
  env overrides the cache). Resolves the key like the signing commands: a keychain
  `@name`, a raw `0x` hex key, or the `RAIL0_PRIVATE_KEY` env var.
- `rail0 auth status` — show address / account / expiry. `rail0 auth logout` —
  clear the token.

## Payment id argument

Commands that take a payment id accept **either** the UUID `id` **or** the
`rail0_id` (`0x` + 64 hex); the gateway resolves both. Capture the `rail0_id` from
`create` output and reuse it.

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

All lifecycle commands are atomic (prepare → sign locally → broadcast) and, without
`-w`, return as soon as they have broadcast — the status advances seconds later. Use
`-w` rather than a hand-rolled poll.

- `payments sign <id>` — deposit the payer signature on an already-created payment
  (payer key; no `--yes`). Useful when `create` ran without a key.
- `payments wait <id> [--until <status>] [--timeout 15m]` — block on a payment you
  did not just act on, or on a status rather than one operation.

## Read commands

| Command | Session | Notes |
| --- | --- | --- |
| `payments get <id>` | none | status, balances, expiries, transactions |
| `payments transactions <id>` | none | on-chain attempts; `--sort` |
| `payments list` | **JWT** | your payer/payee payments; `--chain-id`, `--disputed`, `--min-amount`/`--max-amount` (base units), `--created-from`/`--created-to` (ISO-8601), `--sort` |
| `payments history <id>` | **JWT** | chronological timeline |
| `payments disputes <id>` | none | dispute open/close history; `--status open\|closed` |

## Amount formats

- `create` / `capture` / `refund` `--amount`: **decimal** token units (`"10.50"`);
  the gateway converts to base units.
- `payments list` `--min-amount`/`--max-amount`: **base units** (integers).
