#!/bin/bash
# ledger-integrity-chain.sh — tamper-evident hash chain for the onboarding
#                             status ledger.
#
# Hook    : PreToolUse:Write|Edit (verify) + PostToolUse:Write|Edit (record)
# Mode    : DENY (Pre) / RECORD (Post)
# State   : tests/e2e/docs/.ledger-integrity.json (sidecar, last 20 records)
#
# Why
# ---
# protected-artifact-bash-guard.sh PREVENTS the obvious out-of-band write
# vectors; this hook DETECTS the rest. Sanctioned writes (Write/Edit tools,
# which fire PostToolUse) append the resulting file hash to the sidecar.
# Out-of-band mutations never fire Write|Edit hooks, so the file drifts
# from the sidecar — the next gate check denies until the operator
# intervenes. The sidecar itself is on the bash-guard's protected list and
# is not writable via Write/Edit either (this hook denies direct writes).
#
# Recovery from a detected mismatch: the OPERATOR (human) either restores
# the ledger to its last sanctioned content, or deletes the sidecar in
# their own terminal — an auditable human action outside the agent's tools.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-hooks.md

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[ledger-integrity-chain] FATAL: jq not found." >&2; exit 1; }
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hash.sh"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) ;; *) exit 0 ;; esac
EVENT=$(echo "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

emit_deny() {
  "$JQ" -n --arg r "$1" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
}

# Deny any direct Write/Edit to the sidecar itself (only this hook's Post
# path may author it).
#
# Chain coverage extends beyond the onboarding ledger to the two
# orchestrator-written progress files (cycle + coverage state): each
# sanctioned Write/Edit records the resulting hash; an out-of-band mutation
# then drifts from the chain and is denied on the next sanctioned write.
# The records are keyed by file basename inside the single sidecar.
# Match against a leading-slash-normalised form so a bare relative path
# (tests/e2e/docs/onboarding-status.json) is gated like an absolute one.
CHAIN_KEY=""
NORM_PATH="/${FILE_PATH#/}"
case "$NORM_PATH" in
  */tests/e2e/docs/.ledger-integrity.json | \
  */tests/perf/docs/.ledger-integrity.json)
    [ "$EVENT" = "PreToolUse" ] && emit_deny "[BLOCKED] The integrity sidecar .ledger-integrity.json is hook-authored state. It is never written via Write/Edit — it updates automatically when the ledger is written through the sanctioned path."
    exit 0 ;;
  */tests/e2e/docs/onboarding-status.json)        CHAIN_KEY="onboarding-status.json" ;;
  */tests/perf/docs/perf-onboarding-status.json)  CHAIN_KEY="perf-onboarding-status.json" ;;
  */tests/e2e/docs/.phase4-cycle-state.json)      CHAIN_KEY=".phase4-cycle-state.json" ;;
  */tests/e2e/docs/coverage-expansion-state.json) CHAIN_KEY="coverage-expansion-state.json" ;;
  *) exit 0 ;;
esac

SIDECAR="$(dirname "$FILE_PATH")/.ledger-integrity.json"

# The onboarding ledger uses the legacy flat `.records[]` chain (preserved
# for backward compatibility); the two progress files use a per-file chain
# under `.keyedRecords["<basename>"][]`. Pick the read/write jq path.
if [ "$CHAIN_KEY" = "onboarding-status.json" ] || [ "$CHAIN_KEY" = "perf-onboarding-status.json" ]; then
  CHAIN_FILTER_GET='.records'
else
  CHAIN_FILTER_GET=".keyedRecords[\"$CHAIN_KEY\"]"
fi

if [ "$EVENT" = "PostToolUse" ]; then
  # RECORD: hash the on-disk result of the sanctioned write.
  [ -f "$FILE_PATH" ] || exit 0
  DIGEST=$(file_sha256 "$FILE_PATH")
  [ -n "$DIGEST" ] || exit 0   # no hashing tool — chain disabled, never jam
  NOW=$(date +%s)
  BASE='{}'
  [ -f "$SIDECAR" ] && BASE=$(cat "$SIDECAR" 2>/dev/null || echo '{}')
  if [ "$CHAIN_KEY" = "onboarding-status.json" ] || [ "$CHAIN_KEY" = "perf-onboarding-status.json" ]; then
    UPDATED=$(printf '%s' "$BASE" | "$JQ" --arg d "$DIGEST" --argjson t "$NOW" \
      '.records = ((.records // []) + [{sha256:$d, ts:$t}] | .[-20:])' 2>/dev/null || echo "")
  else
    UPDATED=$(printf '%s' "$BASE" | "$JQ" --arg d "$DIGEST" --argjson t "$NOW" --arg k "$CHAIN_KEY" \
      '.keyedRecords = ((.keyedRecords // {})) | .keyedRecords[$k] = (((.keyedRecords[$k]) // []) + [{sha256:$d, ts:$t}] | .[-20:])' 2>/dev/null || echo "")
  fi
  [ -n "$UPDATED" ] && printf '%s' "$UPDATED" > "$SIDECAR"
  exit 0
fi

[ "$EVENT" = "PreToolUse" ] || exit 0

# VERIFY before permitting a new sanctioned write.
if [ ! -f "$SIDECAR" ]; then
  exit 0   # bootstrap: first sanctioned write will create the chain
fi
LATEST=$("$JQ" -r "${CHAIN_FILTER_GET}[-1].sha256 // empty" "$SIDECAR" 2>/dev/null || echo "")
PREVIOUS=$("$JQ" -r "${CHAIN_FILTER_GET}[-2].sha256 // empty" "$SIDECAR" 2>/dev/null || echo "")
[ -n "$LATEST" ] || exit 0   # malformed sidecar / no chain for this file — bootstrap

if [ ! -f "$FILE_PATH" ]; then
  emit_deny "[BLOCKED] ${CHAIN_KEY} has been deleted out of band — the integrity sidecar still holds its sanctioned hash chain.

Deleting a chained pipeline-state file resets the gates that depend on it;
that is an operator decision, not an agent action.

Fix: ask the user to confirm the reset. The user removes BOTH files in
their own terminal:
  rm tests/e2e/docs/${CHAIN_KEY} tests/e2e/docs/.ledger-integrity.json
Until then, writes and dispatches that depend on it stay blocked."
  exit 0
fi

CURRENT=$(file_sha256 "$FILE_PATH")
[ -n "$CURRENT" ] || exit 0   # no hashing tool — chain disabled
if [ "$CURRENT" != "$LATEST" ] && [ "$CURRENT" != "$PREVIOUS" ]; then
  emit_deny "[BLOCKED] ${CHAIN_KEY} was mutated out of band — its content no longer matches the sanctioned hash chain.

On-disk sha256:   ${CURRENT}
Last sanctioned:  ${LATEST}

Every sanctioned write (Write/Edit through the gates) records its hash in
.ledger-integrity.json. A mismatch means something else changed the file
— a shell write, an external editor, or manual tampering.

Fix: surface this to the user. Recovery is an operator action: the user
either restores the file's sanctioned content or, to accept the
out-of-band state, deletes tests/e2e/docs/.ledger-integrity.json in their
own terminal. The agent cannot self-clear this block."
  exit 0
fi
exit 0
