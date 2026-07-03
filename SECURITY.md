# Security

This skill drives the [`rail0` CLI](https://github.com/commercelayer/rail0-cli) to
make stablecoin payments. Agent Skills run with the agent's full permissions, so
here is exactly what it does — and does not do.

## Private keys never leave your machine

The skill signs transactions **locally** via the `rail0` CLI and sends only the
resulting **signatures** and **signed transactions** to the gateway — never the
private key. Keys are supplied **by reference** (an OS-keychain `@name` or the
`RAIL0_PRIVATE_KEY` env var), never embedded in the skill or pasted inline. The
skill explicitly instructs against inline raw keys, committing `.env`, or logging
secrets (see the *"Signing keys — reference them, never embed them"* section of
`SKILL.md`).

## No secrets in this repository

The skill and its example prompts use placeholder addresses and key **aliases**
only. No private keys, JWTs, or other secrets are committed here.

## What it executes

It invokes the `rail0` CLI — `payments …`, `auth login`, `keys`, `chains`,
`tokens`, `health` — and reads their `--json` output with `jq`. The CLI makes
HTTPS requests only to the rail0 gateway you configure via `RAIL0_BASE_URL`. The
skill does **not** fetch or execute remote code, and bundles no install scripts;
the only shell it uses is the small inline `wait_for` polling function shown in
`SKILL.md`, which just calls `rail0 payments get` in a loop.

## Funds move on-chain

`capture`, `charge`, and `refund` move real value on mainnet (test funds on a
testnet). For mainnet, the skill instructs confirming the amount, token, chain,
and payer/payee with the user before broadcasting an irreversible operation.

## Reporting

Found a security issue in this skill? Please open an issue at
<https://github.com/commercelayer/rail0-skill/issues> or contact the maintainers.
