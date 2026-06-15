#!/bin/bash
# protected-artifact-bash-guard.sh — denies Bash commands that mutate the
#                                    pipeline-state artifacts out of band.
#
# Hook    : PreToolUse:Bash
# Mode    : DENY
# State   : none (stateless pattern check)
# Env     : none
#
# Why
# ---
# Every Write|Edit gate (ledger write-gate, sentinel gate, integrity chain)
# inspects ONLY the Write/Edit tools. A `cat > onboarding-status.json` from
# Bash sidesteps them all. This guard closes the obvious shell vectors:
# redirection, file-management commands, in-place editors, and interpreter
# one-liners that mention a protected artifact.
#
# Known limit (by design): Bash filtering cannot be airtight — the agent
# shares the hook's privileges, and arbitrarily-encoded writes exist. The
# tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS whatever
# this guard fails to PREVENT. The two ship as a pair.
#
# False-positive tradeoff (accepted): any mutate verb (cp/mv/rm/tee/…) or
# interpreter one-liner (-c/-e) co-occurring with a protected name anywhere
# in the command is denied — even when the verb targets an unrelated path
# (e.g. `rm /tmp/junk && cat <ledger>` denies, as does `cp <ledger> /tmp`).
# The deny text names the sanctioned alternative.
#
# settings.local.json: coverage is a deliberate superset of spec §A3's
# settings.json — local overrides carry the same mutation risk.
#
# Canonical reference
# -------------------
# docs/superpowers/specs/2026-06-12-phase1-harness-integrity-design.md §A3

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[protected-artifact-bash-guard] FATAL: jq not found." >&2; exit 1; }

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
if [ -f "$HOOK_LIB_DIR/no-skip-messaging.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOOK_LIB_DIR/no-skip-messaging.sh"
else
  no_skip_messaging_block() { echo ""; }
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Protected artifact patterns (extended regex).
PROTECTED='onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|flake-quarantine\.md|\.claude/hooks|\.claude/settings(\.local)?\.json'

echo "$CMD" | grep -qE "$PROTECTED" || exit 0

# 1. Redirection targeting a protected path (including >| clobber redirect).
REDIR_HIT=$(echo "$CMD" | grep -cE ">>?\|?[[:space:]]*[^[:space:];|&]*(${PROTECTED})" || true)

# 2. Mutation commands co-occurring with a protected name anywhere.
MUTATE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(tee|cp|mv|rm|install|ln|truncate|sponge|shred)([[:space:]]|$)" || true)

# 3. In-place editors (sed, perl, yq -i). Note: jq has no -i flag; redirects already cover jq writes.
INPLACE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(sed|perl|yq)[[:space:]][^;|&]*-i" || true)
DD_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])dd[[:space:]][^;|&]*of=" || true)

# 4. Interpreter one-liners (-c/-e) mentioning a protected path.
#    A bare interpreter one-liner is NOT itself a write — `python3 -c
#    json.load(...)` and `node -e readFileSync(...)` are read-only and must
#    NOT be denied (the prior unconditional INTERP_HIT denied every
#    interpreter that mentioned a protected name, a high-volume false
#    positive on legitimate reads). We split the signal:
#      - INTERP_WRITE_HIT: interpreter one-liner that ALSO carries a
#        recognizable write-shape token → DENY (fail-closed, the real risk).
#      - INTERP_AMBIG_HIT: interpreter one-liner with NO recognizable
#        read/write token → permissionDecision "ask" (can't classify it;
#        defer to the operator rather than deny a possibly-read).
INTERP_ANY_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(python3?|node|ruby|perl)[[:space:]][^;|&]*-[ce]([[:space:]]|$)" || true)

# Write-shape tokens: open(…, 'w'/'a'/'x'), .write(), .write_text(),
# json.dump(), fs.write/append/rm/unlink/rename, writeFileSync,
# os.remove/unlink/rename/truncate, shutil.*, File.write/delete, unlink(.
WRITE_SHAPE_RE="open\\([^)]*,[[:space:]]*[\"'][wax]|\\.write\\(|\\.write_text\\(|json\\.dump\\(|fs\\.(write|append|rm|unlink|rename)|writeFileSync|os\\.(remove|unlink|rename|truncate)|shutil\\.|File\\.(write|delete)|unlink\\("
# Read-shape tokens: anything that reads (open(…, 'r')/default, readFileSync,
# json.load, .read(), .read_text(), File.read). Used only to decide
# ask-vs-deny on an interpreter one-liner with no write-shape.
READ_SHAPE_RE="open\\(|readFileSync|readFile\\(|json\\.load|\\.read\\(|\\.read_text\\(|File\\.read|cat\\("

INTERP_WRITE_HIT=0
INTERP_AMBIG_HIT=0
if [ "$INTERP_ANY_HIT" != "0" ]; then
  if echo "$CMD" | grep -qE "$WRITE_SHAPE_RE"; then
    INTERP_WRITE_HIT=1
  elif echo "$CMD" | grep -qE "$READ_SHAPE_RE"; then
    INTERP_WRITE_HIT=0   # recognizably read-only — allow
  else
    INTERP_AMBIG_HIT=1   # no recognizable read/write token — ask
  fi
fi

# Ambiguous interpreter one-liner (protected path mentioned, but no
# recognizable read or write token) → ask the operator rather than deny.
if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ] && [ "$INTERP_AMBIG_HIT" = "1" ]; then
  "$JQ" -n --arg r "[ASK] This Bash command runs an interpreter one-liner that mentions a protected pipeline-state artifact, but the harness cannot tell whether it reads or writes it.

Command: ${CMD}

If this only READS the artifact, approve it. If it WRITES the artifact, cancel and use the Write/Edit tool instead (that is where the harness gates live).

See: docs/superpowers/specs/2026-06-12-phase1-harness-integrity-design.md §A3" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": $r
    }
  }'
  exit 0
fi

if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ]; then
  exit 0   # read-only access to a protected artifact
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: drop the write-shaped construct (redirect into /tmp, not
    into the artifact; copy FROM it is blocked too — use cat/jq to read).
  - Deleting a pipeline-state artifact is an operator decision: ask the
    user to remove it in their own terminal if a reset is intended.

$(no_skip_messaging_block)"

"$JQ" -n --arg r "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
