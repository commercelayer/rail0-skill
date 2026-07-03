# rail0-skill

A [Claude Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
that teaches an AI agent to make and manage stablecoin (USDC) payments through the
[rail0](https://rail0.xyz) gateway using the **`rail0` CLI** — the full
authorize → capture lifecycle plus charge, void, release, refund, and dispute.

## Install

```sh
npx skills add commercelayer/rail0-skill
```

## What it does

The skill teaches the payment mental model (payer/payee, escrow vs one-shot, the
two on-chain balances), how to supply signing keys safely, and the core
**act → poll** pattern — every lifecycle command broadcasts asynchronously, then
you poll the payment to its settled status. It covers, with ready recipes:

- **authorize → capture** (partial or full) — the escrow flow
- **charge** — one-shot, no escrow
- **void** — cancel an untouched authorization
- **release** — return the uncaptured escrow after expiry
- **refund** — return captured funds
- **dispute / close** — the buyer-driven signal

## Requirements

- The [`rail0` CLI](https://github.com/commercelayer/rail0-cli) on `PATH`
- `jq` (for reading the CLI's `--json` output)
- Access to a rail0 gateway (set `RAIL0_BASE_URL`)

## Layout

- [`SKILL.md`](SKILL.md) — the skill (mental model, setup, recipes, error handling)
- [`references/`](references/) — lifecycle/state-machine and full command reference
- [`scripts/`](scripts/) — `wait_for_status.sh`, the poller the skill uses
- [`evals/`](evals/) — the test prompts used to validate the skill
