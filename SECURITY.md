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
skill does **not** fetch or execute remote code, and bundles no install scripts
or shell helpers: waiting for on-chain confirmation is the CLI's own `-w` flag and
`rail0 payments wait`.

## Capability: direct money access (by design)

Security scanners flag this skill for **direct money-access capability** (e.g.
`W009`, MEDIUM). That is correct and expected: moving stablecoins *is* the skill's
purpose — `authorize`/`capture`/`charge` pull funds from the payer, `refund`/`void`/
`release` return them, and every operation broadcasts an **irreversible** on-chain
transaction. It is a capability disclosure, not a vulnerability. The finding cannot
be removed without removing the skill's function; instead it is **mitigated**:

- **Human in the loop.** The skill instructs the agent to restate the amount,
  token, chain, and payer/payee and get **explicit user approval before every
  fund-moving broadcast** — never broadcasting an operation the user didn't ask for
  (mandatory on mainnet). See the *Safety* section of `SKILL.md`.
- **Keys stay local** (above) — the capability is exercised only with a key the
  operator supplies on their own machine; the skill can't move funds on its own.
- **Testnet-first** guidance while developing or when parameters are uncertain.
- **Amount ceilings** — captures/refunds are bounded by the on-chain
  `capturable_amount` / `refundable_amount`, re-read before acting.

## Reporting

Found a security issue in this skill? Please open an issue at
<https://github.com/commercelayer/rail0-skill/issues> or contact the maintainers.
