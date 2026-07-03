#!/usr/bin/env bash
# wait_for_status.sh — poll a rail0 payment until it reaches an expected status.
#
# rail0 lifecycle commands are asynchronous: they broadcast and return (HTTP 202),
# and the payment's status advances a few seconds later when the transaction
# confirms on-chain. This blocks until the payment reaches <expected-status>, so a
# flow can proceed step-by-step without racing the chain.
#
# Usage:   wait_for_status.sh <payment-id-or-rail0_id> <expected-status> [timeout-secs]
# Exit 0:  status reached <expected-status>.
# Exit 1:  the latest on-chain transaction failed, or the timeout elapsed.
# Exit 2:  missing dependency / bad usage.
#
# Reads the gateway target from the same place the CLI does (RAIL0_BASE_URL /
# config), since it just shells out to `rail0 payments get`.
set -euo pipefail

id="${1:?usage: wait_for_status.sh <payment-id-or-rail0_id> <expected-status> [timeout-secs]}"
expected="${2:?expected status required (e.g. authorized, captured, charged, refunded, voided, released)}"
timeout="${3:-120}"
interval=2
elapsed=0

command -v rail0 >/dev/null 2>&1 || { echo "wait_for_status: the 'rail0' CLI is not on PATH" >&2; exit 2; }
command -v jq    >/dev/null 2>&1 || { echo "wait_for_status: 'jq' is required" >&2; exit 2; }

while :; do
  json="$(rail0 payments get "$id" --json 2>/dev/null || true)"
  if [ -n "$json" ]; then
    status="$(printf '%s' "$json" | jq -r '.status // empty')"

    if [ "$status" = "$expected" ]; then
      echo "✓ $id → $status"
      exit 0
    fi

    # Surface a failed broadcast instead of spinning until the timeout. Transactions
    # come oldest-first, so `last` is the most recent attempt — the one we just made.
    last_status="$(printf '%s' "$json" | jq -r '(.transactions // []) | last | .status // empty')"
    if [ "$last_status" = "failed" ]; then
      err="$(printf '%s' "$json" | jq -r '(.transactions // []) | last | (.error_message // .error_reason // .error_code // "reverted")')"
      echo "✗ $id: latest transaction failed — $err (payment status: ${status:-unknown})" >&2
      exit 1
    fi
  fi

  if [ "$elapsed" -ge "$timeout" ]; then
    echo "✗ $id: timed out after ${timeout}s waiting for '$expected' (current status: ${status:-unknown})" >&2
    exit 1
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done
