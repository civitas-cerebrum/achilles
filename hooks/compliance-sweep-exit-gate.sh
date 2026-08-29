#!/bin/bash
# compliance-sweep-exit-gate.sh — no test-authoring session ends without the
# Stage-4b compliance sweep.
#
# Hook    : Stop, SubagentStop
# Mode    : BLOCK (exit 2 + stderr feedback) when this session wrote or edited
#           a spec file and no compliance sweep ran after that write
# State   : reads the session transcript at `transcript_path` from the hook
#           input; no state of its own
# Env     : CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE=1 disables the hook
#
# Rule
# ----
# Every working mode that develops tests — authoring (achilles-protocol
# Stages 1-4), composition (test-composer), coverage expansion, bug-discovery
# reproduction tests, ticket-driven testing, companion-mode graduation, and
# every repair mode that edits test code (self-repair, test-repair,
# failure-diagnosis heals) — ends with the Stage-4b compliance sweep over the
# tests it touched. This gate reads the transcript at stop time: if the last
# Write/Edit of a `*.spec.*` / `*.test.*` / `*.setup.*` file is not followed by
# a sweep announcement, the stop is blocked with the sweep's checklist.
#
# Why
# ---
# The sweep is where API misuse, tautological assertions, missing test IDs and
# untagged intentional reds are caught. Modes that write tests as a *means* to
# something else — reproducing a bug, healing a red, closing a ticket — are
# exactly the ones that skip it, because the mode's own goal reads as met the
# moment the test exists. Skipped once, the misuse propagates into every test
# written after it from the same wrong mental model. A markdown "always run the
# sweep" line is read at the start of a session and rationalised away at the
# end of one; a stop-time gate is read at the end, which is when it matters.
#
# Evidence accepted (case-insensitive, in assistant text after the last spec
# write): "API Compliance Review" — the sweep's documented output heading —
# or a "stage=4b" / "compliance sweep" announcement.
#
# Loop safety: `stop_hook_active` means this gate already blocked once in the
# current stop chain, so it allows — one block per chain, never a trap.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/stages-protocol.md §"Stage 4b: API
#   Compliance Review" and §"Stage 4b is every mode's exit gate"
# skills/achilles-protocol/references/test-identity.md
#
# Failure → action
# ----------------
# - Spec file written/edited, no sweep after it              → BLOCK (exit 2)
# - Sweep announced after the last spec write                → silent allow
# - No spec file touched this session                        → silent allow
# - stop_hook_active / no transcript / kill-switch           → silent allow

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

INPUT=$(cat)

# Session-scope gate: achilles-activated sessions only.
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$INPUT"

[ "${CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE:-0}" = "1" ] && exit 0

# Already blocked once in this stop chain — never trap the session.
STOP_ACTIVE=$(echo "$INPUT" | "$JQ" -r '.stop_hook_active // false' 2>/dev/null || echo "false")
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT_PATH=$(echo "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")
[ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

# Last transcript line carrying a Write/Edit of a spec-shaped file.
LAST_SPEC_WRITE=$(
  "$JQ" -r '
    (input_line_number) as $n |
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "tool_use")
      | select(.name? == "Write" or .name? == "Edit")
      | (.input.file_path // "")
      | select(test("\\.(spec|test|setup)\\.(m|c)?(t|j)sx?$"))
      | "\($n)"
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1
)
[ -n "$LAST_SPEC_WRITE" ] || exit 0

# Last transcript line carrying sweep evidence in assistant prose.
LAST_SWEEP=$(
  "$JQ" -r '
    (input_line_number) as $n |
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "text")
      | (.text // "")
      | select(test("api compliance review|stage=4b|compliance sweep"; "i"))
      | "\($n)"
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1
)

if [ -n "$LAST_SWEEP" ] && [ "$LAST_SWEEP" -ge "$LAST_SPEC_WRITE" ] 2>/dev/null; then
  exit 0
fi

SPEC_FILES=$(
  "$JQ" -r '
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "tool_use")
      | select(.name? == "Write" or .name? == "Edit")
      | (.input.file_path // "")
      | select(test("\\.(spec|test|setup)\\.(m|c)?(t|j)sx?$"))
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u | head -8 | sed 's/^/    /'
)

cat >&2 <<EOF
[BLOCKED] Test code changed in this session, but the Stage-4b compliance sweep never ran.

──────────────────────────
Do this instead — run the sweep now, then stop:
──────────────────────────
  1. Read skills/achilles-protocol/references/api-reference.md (from the
     file, not from memory) and re-read each spec you touched:
$SPEC_FILES
  2. Run the 12 checks in stages-protocol.md §"Stage 4b: API Compliance
     Review" over those files — signatures, imports, naming, repo-backed
     selectors, no raw Playwright, fixture usage, waits, verification shapes,
     a non-tautological final assertion, and check 12: every case carries a
     stable test ID and every intentional red carries \`@known-defect\`.
  3. Fix what it finds, re-run the affected tests, and post the sweep's
     documented output block — the line **API Compliance Review** followed by
     the files reviewed and the issues found (or "no issues found").

──────────────────────────
What was wrong:
──────────────────────────
The transcript shows a Write/Edit of a spec file with no compliance sweep
after it. Whatever the session's headline goal was — a new scenario, a bug
reproduction, a heal, a ticket — writing test code makes the sweep part of
finishing, not an optional extra step. A test that passes while misusing the
API is a test that will be copied.

──────────────────────────
If the tests came out of a subagent — read this:
──────────────────────────
Delegation moves the work, not the obligation: either the subagent ran the
sweep and said so in its return, or you run it here over what it wrote.

How this is supposed to be done — load the skill, don't improvise:
  Skill('achilles-protocol') → Stage 4b, the sweep and its checklist
    (pre-rename installs: Skill('element-interactions') — same skill, same stage)
  skills/achilles-protocol/references/stages-protocol.md §"Stage 4b: API Compliance Review"
  skills/achilles-protocol/references/test-identity.md → check 12's conventions
  Skill('test-composer') → Step 6b, the same sweep inside a journey pass

Kill-switch (document the authorisation): CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE=1
EOF
exit 2
