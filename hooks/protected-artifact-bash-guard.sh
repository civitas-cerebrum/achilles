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
# skills/element-interactions/references/harness-hooks.md

set -uo pipefail

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/guard-common.sh
if [ -f "$HOOK_LIB_DIR/guard-common.sh" ]; then source "$HOOK_LIB_DIR/guard-common.sh"; fi

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
# Fail CLOSED when jq is missing — this guard is the only thing standing
# between a Bash write and the protected pipeline-state artifacts. Denying a
# Bash command when jq is absent is disruptive but safe; allowing one is not.
if [ -z "$JQ" ]; then
  command -v guard_emit_deny_no_jq >/dev/null 2>&1 && guard_emit_deny_no_jq "protected-artifact-bash-guard" \
    || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] protected-artifact-bash-guard cannot run: jq not found. Fails closed. Reinstall @civitas-cerebrum/achilles or install jq."}}'
  exit 0
fi

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
PROTECTED='onboarding-status\.json|perf-onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|flake-quarantine\.md|\.claude/hooks|\.claude/settings(\.local)?\.json'

# Split-token evasion for the harness surface: an agent can defeat the
# contiguous `.claude/settings.json` match by assembling the path in a
# variable — `D=$HOME/.claude; echo {} > "$D/settings.json"` — where
# `.claude` and `settings.json` never appear adjacent. When the command
# mentions `.claude` at all AND a bare settings/hooks token anywhere, treat
# it as a protected hit and (below) broaden the redirect-target match to the
# bare tokens. This accepts extra false positives on the rare case of an
# unrelated project settings.json referenced next to a `.claude` mention —
# but such a bash write should go through the Write tool anyway, and a
# read-only mention still exits 0 further down.
CLAUDE_CONTEXT=0
echo "$CMD" | grep -qE '\.claude([^a-zA-Z0-9]|$)' && CLAUDE_CONTEXT=1
SPLIT_HIT=0
if [ "$CLAUDE_CONTEXT" = "1" ] && echo "$CMD" | grep -qE 'settings(\.local)?\.json|(^|[/[:space:]"'\''])hooks/'; then
  SPLIT_HIT=1
fi

if ! echo "$CMD" | grep -qE "$PROTECTED" && [ "$SPLIT_HIT" = "0" ]; then
  exit 0
fi

# Redirect-target alternation. Under a `.claude` context, also treat the
# bare settings tokens as protected redirect targets (split-token case).
REDIR_TARGET_RE="$PROTECTED"
[ "$SPLIT_HIT" = "1" ] && REDIR_TARGET_RE="${PROTECTED}|settings(\\.local)?\\.json"

# 1. Redirection targeting a protected path (including >| clobber redirect).
REDIR_HIT=$(echo "$CMD" | grep -cE ">>?\|?[[:space:]]*[^[:space:];|&]*(${REDIR_TARGET_RE})" || true)

# 2. Mutation commands co-occurring with a protected name anywhere.
MUTATE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(tee|cp|mv|rm|install|ln|truncate|sponge|shred)([[:space:]]|$)" || true)

# 3. In-place editors (sed, perl, yq -i). Note: jq has no -i flag; redirects already cover jq writes.
INPLACE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(sed|perl|yq)[[:space:]][^;|&]*-i" || true)
DD_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])dd[[:space:]][^;|&]*of=" || true)

# 3b. find … -delete / find … -exec <mutator>: a cheap way to remove or
#     rewrite a protected artifact that carries no redirect and no mutate
#     verb at the top level.
FIND_DELETE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])find[[:space:]][^;|&]*(-delete|-exec[[:space:]]+(rm|truncate|tee|sed|mv|cp|dd)([[:space:]]|$))" || true)

# 3c. Line editors / patchers that mutate a named file in place without an
#     -i flag: `ed`, `ex`, `vi -es`, `patch`. `ed`/`ex` require a boundary
#     char before them so `sed`/`export` don't match.
EDITOR_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(ed|ex|patch)([[:space:]]|$)|(^|[;&|[:space:]])vi[[:space:]][^;|&]*-e?s" || true)

# 4. Interpreter invocations mentioning a protected path. Covers three
#    launch shapes: `-c`/`-e` one-liners, a bare `-` stdin script, and a
#    heredoc (`python3 - <<EOF`). A bare interpreter that only READS is not
#    a write — `python3 -c json.load(...)` / `node -e readFileSync(...)` /
#    `python3 - <<'EOF'\njson.load(open(...))\nEOF` must NOT be denied. We
#    split the signal:
#      - INTERP_WRITE_HIT: interpreter invocation that ALSO carries a
#        recognizable write-shape token → DENY (fail-closed, the real risk).
#      - INTERP_AMBIG_HIT: interpreter invocation with NO recognizable
#        read/write token → permissionDecision "ask" (can't classify it;
#        defer to the operator rather than deny a possibly-read).
INTERP_ANY_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(python3?|node|ruby|perl)[[:space:]]([^;|&]*-[ce]([[:space:]]|$)|-([[:space:]]|$)|[^;|&]*<<)" || true)

# Write-shape tokens: open(…, 'w'/'a'/'x'), .write(), .write_text(),
# json.dump(), fs.write/append/rm/unlink/rename, writeFileSync,
# os.remove/unlink/rename/truncate, shutil.*, File.write/delete, unlink(.
WRITE_SHAPE_RE="open\\([^)]*,[[:space:]]*[\"'][wax]|\\.write\\(|\\.write_text\\(|json\\.dump\\(|fs\\.(write|append|rm|unlink|rename)|writeFileSync|os\\.(remove|unlink|rename|truncate)|shutil\\.|File\\.(write|delete)|unlink\\("
# Read-shape tokens: anything that reads (open(…, 'r')/default, readFileSync,
# json.load, .read(), .read_text(), File.read, require(<json>) — the Node
# load+parse idiom). Used only to decide ask-vs-deny on an interpreter
# one-liner with no write-shape. require() is read-only for a JSON file; a
# require() that also writes still carries a write-shape, which is classified
# first (above), so this can never launder a write into an allow.
READ_SHAPE_RE="open\\(|readFileSync|readFile\\(|json\\.load|\\.read\\(|\\.read_text\\(|File\\.read|require\\(|cat\\("

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
# An unambiguous write vector (redirect / mutate / editor / find-delete)
# takes precedence over the ask path below.
if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$FIND_DELETE_HIT" = "0" ] && [ "$EDITOR_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ] && [ "$INTERP_AMBIG_HIT" = "1" ]; then
  "$JQ" -n --arg r "[ASK] This Bash command runs an interpreter one-liner that mentions a protected pipeline-state artifact, but the harness cannot tell whether it reads or writes it.

Command: ${CMD}

If this only READS the artifact, approve it. If it WRITES the artifact, cancel and use the Write/Edit tool instead (that is where the harness gates live).

See: skills/element-interactions/references/harness-hooks.md" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": $r
    }
  }'
  exit 0
fi

if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$FIND_DELETE_HIT" = "0" ] && [ "$EDITOR_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ]; then
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
