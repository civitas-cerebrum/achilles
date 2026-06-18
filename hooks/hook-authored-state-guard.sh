#!/bin/bash
# hook-authored-state-guard.sh — protects hook-authored state files from
#                                direct Write|Edit, and gates monotonicity
#                                of orchestrator-written progress state.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY
# State   : reads the on-disk prior version of the gated file (when present)
# Env     : none
#
# Why
# ---
# Two classes of pipeline-state file need write-side protection that the
# schema/state-machine gates don't provide:
#
#   1. HOOK-AUTHORED state — never written via Write/Edit at all. The
#      approver registry (.workflow-approvers.json, authored by
#      workflow-approver-registry.sh) and the integrity sidecar
#      (.ledger-integrity.json, authored by ledger-integrity-chain.sh's
#      Post path). A direct Write|Edit to either is forgery of the
#      separation-of-duties / tamper-evidence substrate. We DENY outright,
#      mirroring ledger-integrity-chain.sh's own sidecar self-deny
#      (ledger-integrity-chain.sh:47-50) and extending the same treatment
#      to the approver registry.
#
#   2. ORCHESTRATOR-WRITTEN progress state that is legitimately authored
#      via Write|Edit but must only GROW: .phase4-cycle-state.json and
#      coverage-expansion-state.json. A write that SHRINKS or REWRITES the
#      dispatched/returned arrays (or the passes.N.dispatched-journeys) is
#      rewriting history to hide work that was supposed to happen — the
#      "dispatched 7, rewrite to claim 3, mark done" forgery. We gate:
#        - cycles.N.dispatched-sections / returned-sections must not shrink
#          or have elements removed.
#        - passes.N.dispatched-journeys / returned-journeys must not shrink
#          or have elements removed.
#        - a FIRST write (no prior file) that already contains a non-empty
#          returned-sections / returned-journeys is denied — returns cannot
#          predate any dispatch record.
#
# The integrity sidecar's hash chain (ledger-integrity-chain.sh) only
# covers onboarding-status.json; this guard extends comparable write-side
# discipline to the cycle/coverage progress files.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-hooks.md
# hooks/ledger-integrity-chain.sh (sibling — sidecar self-deny + chain)

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[hook-authored-state-guard] FATAL: jq not found." >&2; exit 1; }

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) ;; *) exit 0 ;; esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
  exit 0
}

# Normalise to leading-slash form so bare relative paths match the same
# suffix patterns as absolute ones.
NORM="/${FILE_PATH#/}"

# --- Class 1: hook-authored state — never Write|Edit. ---
case "$NORM" in
  */tests/e2e/docs/.workflow-approvers.json | \
  */tests/perf/docs/.workflow-approvers.json)
    emit_deny "[BLOCKED] .workflow-approvers.json is hook-authored state.

File: ${FILE_PATH}

The approver registry is written ONLY by hooks/workflow-approver-registry.sh
when a workflow-reviewer-* / phase-validator-* Agent dispatch fires. A direct
Write|Edit forges the separation-of-duties substrate the ledger-write-gate
relies on to verify that approvals come from a registered approver context.

Fix: do not write this file. Dispatch the approver subagent with the correct
description prefix; the registry hook records it automatically."
    ;;
  */tests/e2e/docs/.ledger-integrity.json | \
  */tests/perf/docs/.ledger-integrity.json)
    emit_deny "[BLOCKED] .ledger-integrity.json is hook-authored state.

File: ${FILE_PATH}

The integrity sidecar is written ONLY by hooks/ledger-integrity-chain.sh's
PostToolUse path. It updates automatically when the ledger is written through
the sanctioned Write/Edit path. A direct Write|Edit forges the tamper-evidence
hash chain.

Fix: do not write this file. To accept an out-of-band ledger state, the
operator deletes the sidecar in their own terminal."
    ;;
esac

# --- Class 2: monotonicity of orchestrator-written progress state. ---
IS_CYCLE=0
IS_COV=0
case "$NORM" in
  */tests/e2e/docs/.phase4-cycle-state.json)      IS_CYCLE=1 ;;
  */tests/e2e/docs/coverage-expansion-state.json) IS_COV=1 ;;
  *) exit 0 ;;
esac

# Extract the proposed content. Write → content; Edit → synthesise via the
# validator bundle's `replace` subcommand (literal replacement). If we
# cannot obtain the proposed content (Edit against a missing file, no node),
# silent-allow — the schema/state gates own those failure modes.
PROPOSED=""
case "$TOOL_NAME" in
  Write)
    PROPOSED=$(echo "$INPUT" | "$JQ" -r '.tool_input.content // empty' 2>/dev/null || echo "")
    ;;
  Edit)
    OLD_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.old_string // empty' 2>/dev/null || echo "")
    NEW_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
    REPLACE_ALL=$(echo "$INPUT" | "$JQ" -r '.tool_input.replace_all // false' 2>/dev/null || echo "false")
    if [ -f "$FILE_PATH" ] && [ -n "$OLD_STRING" ]; then
      NODE_BIN="$(command -v node 2>/dev/null || true)"
      VALIDATOR="$(dirname "${BASH_SOURCE[0]}")/lib/validator.bundle.mjs"
      if [ -n "$NODE_BIN" ] && [ -f "$VALIDATOR" ]; then
        TMP_OLD=$(mktemp /tmp/has-old-XXXXXX); TMP_NEW=$(mktemp /tmp/has-new-XXXXXX)
        printf '%s' "$OLD_STRING" > "$TMP_OLD"; printf '%s' "$NEW_STRING" > "$TMP_NEW"
        ALL_FLAG=""; [ "$REPLACE_ALL" = "true" ] && ALL_FLAG="--all"
        PROPOSED=$("$NODE_BIN" "$VALIDATOR" replace "$FILE_PATH" "$TMP_OLD" "$TMP_NEW" $ALL_FLAG 2>/dev/null || echo "")
        rm -f "$TMP_OLD" "$TMP_NEW"
      fi
    fi
    ;;
esac
[ -n "$PROPOSED" ] || exit 0

# Must be parseable JSON for the comparison to be meaningful; if not,
# silent-allow (the consuming gate / schema check owns parse failures).
TMP_NEW_FILE=$(mktemp /tmp/has-proposed-XXXXXX.json)
trap 'rm -f "$TMP_NEW_FILE"' EXIT
printf '%s' "$PROPOSED" > "$TMP_NEW_FILE"
"$JQ" -e . "$TMP_NEW_FILE" >/dev/null 2>&1 || exit 0

# jq helper: is array A a (non-strict) superset of array B (every element of
# B present in A)? Prints "true"/"false".
array_superset() {
  # $1 = new array json, $2 = prior array json
  "$JQ" -n --argjson new "$1" --argjson old "$2" \
    '($old - $new) | length == 0' 2>/dev/null || echo "true"
}

deny_shrink() {
  local field="$1"
  emit_deny "[BLOCKED] Write to $(basename "$FILE_PATH") shrinks or rewrites progress state (${field}).

File: ${FILE_PATH}

This is append-only progress state. Removing or rewriting entries from
${field} hides dispatched/returned work — the 'dispatched N, rewrite to
claim fewer, mark done' forgery. Dispatched and returned rosters only grow.

Fix: do not remove entries already recorded. If a record is genuinely
wrong, surface it to the operator — correcting hook-tracked progress state
is an operator action, not an in-band rewrite."
}

if [ "$IS_CYCLE" = "1" ]; then
  # First-write sanity: returns cannot predate any dispatch record.
  if [ ! -f "$FILE_PATH" ]; then
    NONEMPTY_RETURN=$("$JQ" -r '
      [ (.cycles // {}) | to_entries[] | .value["returned-sections"] // [] | length ] | add // 0
    ' "$TMP_NEW_FILE" 2>/dev/null || echo "0")
    case "$NONEMPTY_RETURN" in ''|*[!0-9]*) NONEMPTY_RETURN=0 ;; esac
    if [ "$NONEMPTY_RETURN" -gt 0 ]; then
      emit_deny "[BLOCKED] First write to .phase4-cycle-state.json already contains non-empty returned-sections.

File: ${FILE_PATH}

A returned-sections roster cannot predate any dispatch record. The first
write of the cycle state records dispatched-sections; returns are recorded
on later writes as section agents come back.

Fix: write the dispatch roster first (returned-sections empty), then record
returns on subsequent writes."
    fi
    exit 0
  fi
  # Per-cycle, neither dispatched-sections nor returned-sections may lose
  # an element.
  for cid in $("$JQ" -r '(.cycles // {}) | keys[]?' "$FILE_PATH" 2>/dev/null); do
    for arr in dispatched-sections returned-sections; do
      OLD_A=$("$JQ" -c --arg c "$cid" --arg a "$arr" '(.cycles[$c][$a]) // []' "$FILE_PATH" 2>/dev/null || echo "[]")
      NEW_A=$("$JQ" -c --arg c "$cid" --arg a "$arr" '(.cycles[$c][$a]) // []' "$TMP_NEW_FILE" 2>/dev/null || echo "[]")
      if [ "$(array_superset "$NEW_A" "$OLD_A")" != "true" ]; then
        deny_shrink "cycles.${cid}.${arr}"
      fi
    done
  done
  exit 0
fi

if [ "$IS_COV" = "1" ]; then
  if [ ! -f "$FILE_PATH" ]; then
    NONEMPTY_RETURN=$("$JQ" -r '
      [ (.passes // {}) | to_entries[] | .value["returned-journeys"] // [] | length ] | add // 0
    ' "$TMP_NEW_FILE" 2>/dev/null || echo "0")
    case "$NONEMPTY_RETURN" in ''|*[!0-9]*) NONEMPTY_RETURN=0 ;; esac
    if [ "$NONEMPTY_RETURN" -gt 0 ]; then
      emit_deny "[BLOCKED] First write to coverage-expansion-state.json already contains non-empty returned-journeys.

File: ${FILE_PATH}

A returned-journeys roster cannot predate any dispatch record. The first
write records dispatched-journeys; returns land on later writes.

Fix: write the dispatch roster first (returned-journeys empty), then record
returns on subsequent writes."
    fi
    exit 0
  fi
  for pid in $("$JQ" -r '(.passes // {}) | keys[]?' "$FILE_PATH" 2>/dev/null); do
    for arr in dispatched-journeys returned-journeys; do
      OLD_A=$("$JQ" -c --arg p "$pid" --arg a "$arr" '(.passes[$p][$a]) // []' "$FILE_PATH" 2>/dev/null || echo "[]")
      NEW_A=$("$JQ" -c --arg p "$pid" --arg a "$arr" '(.passes[$p][$a]) // []' "$TMP_NEW_FILE" 2>/dev/null || echo "[]")
      if [ "$(array_superset "$NEW_A" "$OLD_A")" != "true" ]; then
        deny_shrink "passes.${pid}.${arr}"
      fi
    done
  done
  exit 0
fi

exit 0
