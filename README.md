# rail0-skill

[![Claude Agent Skill](https://img.shields.io/badge/Claude-Agent_Skill-8A2BE2)](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
[![Install via skills.sh](https://img.shields.io/badge/skills.sh-npx_skills_add-111827)](https://skills.sh)
[![rail0](https://img.shields.io/badge/rail0-gateway-00A3FF)](https://rail0.xyz)

> Make and manage **stablecoin (USDC) payments** over the [rail0](https://rail0.xyz)
> gateway from an AI agent — the full **authorize → capture** lifecycle plus
> charge, void, release, refund, and dispute — driven by the `rail0` CLI.

A [Claude Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills).
Point your agent at a rail0 gateway and it can take, capture, refund, or cancel
stablecoin payments *correctly*: the skill encodes the lifecycle rules, who signs
what, and the asynchronous **act → poll** pattern so operations never race the chain.

## Install

```sh
npx skills add commercelayer/rail0-skill
```

Then just ask your agent to make or manage a rail0 payment.

## Quickstart — what the agent runs

```sh
export RAIL0_BASE_URL=https://your-gateway
rail0 auth login -p @payee                            # merchant session (payee-gated ops)

# Authorize 10 USDC into escrow, then capture it (poll between on-chain steps)
PID=$(rail0 payments create -F <payer> -T <payee> -t USDC -a 10.00 -c 5042002 \
        -p @payer --json | jq -r .id)
rail0 payments authorize "$PID" -p @payee
rail0 payments capture   "$PID" -a 10.00 -p @payee
```

## Lifecycle at a glance

| Operation | Who signs | What it does |
|---|---|---|
| **authorize → capture** | payer opens, payee captures | hold funds in escrow, capture later (partial or full) |
| **charge** | payee | one-shot: pay through immediately, no escrow |
| **void** | payee | cancel an untouched authorization (before any capture) |
| **release** | payer or payee | return the uncaptured escrow after `authorizationExpiry` |
| **refund** | payee | return captured funds to the buyer (partial or full) |
| **dispute / close** | payer | buyer signal — no funds move |

See [`references/lifecycle.md`](references/lifecycle.md) for the state machine, guards, and the two on-chain balances that drive the next legal step.

## Requirements

- The [`rail0` CLI](https://github.com/commercelayer/rail0-cli) on your `PATH`
- `jq` (to read the CLI's `--json` output)
- A reachable rail0 gateway — set `RAIL0_BASE_URL`

## What's inside

- [`SKILL.md`](SKILL.md) — the skill: mental model, setup, per-operation recipes, error handling, safety
- [`references/`](references/) — lifecycle/state-machine + the full command reference
- [`scripts/`](scripts/) — `wait_for_status.sh`, the poller the skill uses between on-chain steps
- [`evals/`](evals/) — the test prompts used to validate the skill (4/4 passing end-to-end on Arc testnet)

## Security

Private keys stay local. The CLI signs locally and sends only **signatures and
signed transactions** to the gateway — never the key. Prefer the OS keychain
(`rail0 keys add` → `@name`) or a secrets-manager-injected `RAIL0_PRIVATE_KEY`;
never paste a raw key inline. See the skill's *"Signing keys — reference them,
never embed them"* section.
