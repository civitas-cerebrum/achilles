#!/bin/bash
# test-id-compliance-gate.sh — every test case carries a stable test ID.
#
# Hook    : PreToolUse:Edit|Write
# Mode    : DENY (a spec write that ADDS a test case with no ID in its title,
#           or that introduces a duplicate ID inside the same file)
# State   : none
# Env     : CIVITAS_DISABLE_TEST_ID_GATE=1 disables the hook (kill-switch for
#           consumers who do not use the ID convention)
#           CIVITAS_TEST_ID_PATTERN=<regex source> swaps in another ID shape,
#           anchored at the start of the title with the ID in group 1
#           (e.g. '^\s*([A-Z]{2,4}-[0-9]{2,4})'). Default is the house shape:
#           TC + up to three more letters, dash, 4-6 digits.
#
# Rule
# ----
# The title of every test case begins with a stable identifier — `TCXX-NNNNNN`
# (optionally bracketed) followed by the behaviour sentence, e.g.
# `test('TCLG-000420 · a wrong password is rejected', …)`. This gate fires on
# Write/Edit of a spec-shaped file (*.spec.*, *.test.*, *.setup.*), reconstructs
# the post-write content, and denies when the write introduces a `test(...)` /
# `test.only|skip|fail|fixme(...)` case whose title carries no ID, or an ID that
# now appears twice in the file. `test.describe` and `test.step` are out of
# scope — the case is the unit of identity.
#
# Why
# ---
# Four consumers key on the ID and degrade without it: `--grep`-targeted runs,
# the `bug-evidence/<TEST-ID>/` evidence contract (a title-derived path moves
# the moment the wording is edited, scattering a defect's history), the
# per-test rows in self-repair / test-repair / test-catalogue reports, and
# human traceability between a journey map, a ticket and a PR. Markdown asked
# for IDs and got them on the tests an agent happened to remember the rule for;
# the gate is what makes "every case" true.
#
# Scoped to ADDED titles on purpose: an existing suite that predates the
# convention would otherwise hold every unrelated edit hostage. Migration is
# incremental, file by file, and the gate only ever asks for an ID on a case
# the current write is creating.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/test-identity.md §"Every test case
#   carries a stable ID"
# skills/element-interactions/references/stages-protocol.md §"Stage 4b: API
#   Compliance Review" (check 12)
#
# Failure → action
# ----------------
# - Write/Edit adds a test case whose title has no ID     → DENY
# - Write/Edit makes an ID appear twice in one file       → DENY
# - Untagged case that already existed in the file        → silent allow
# - test.describe / test.step / hook titles               → silent allow
# - Non-spec file, non-Write/Edit tool, kill-switch set   → silent allow

set -euo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HOOK_LIB="$HOOK_DIR/lib"

input=$(cat)

# Session-scope gate: achilles-activated sessions only (lib/achilles-activation.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$input"

emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

[ "${CIVITAS_DISABLE_TEST_ID_GATE:-0}" = "1" ] && exit 0

tool_name=$(echo "$input" | "$JQ" -r '.tool_name // empty')
file_path=$(echo "$input" | "$JQ" -r '.tool_input.file_path // empty')

case "$tool_name" in Edit|Write) ;; *) exit 0 ;; esac
[ -n "$file_path" ] || exit 0

# Spec-shaped files only.
case "$(basename "$file_path")" in
  *.spec.ts|*.spec.tsx|*.spec.mts|*.spec.js|*.spec.mjs|*.spec.jsx) ;;
  *.test.ts|*.test.tsx|*.test.mts|*.test.js|*.test.mjs|*.test.jsx) ;;
  *.setup.ts|*.setup.mts|*.setup.js|*.setup.mjs) ;;
  *) exit 0 ;;
esac

ws="${WORKSPACE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
[ -d "$HOOK_LIB" ] || HOOK_LIB="$ws/hooks/lib"
[ -f "$HOOK_LIB/test-id-scan.js" ] || exit 0

before_content=""
[ -f "$file_path" ] && before_content=$(cat "$file_path")

if [ "$tool_name" = "Write" ]; then
  after_content=$(echo "$input" | "$JQ" -r '.tool_input.content // empty')
else
  old_string=$(echo "$input" | "$JQ" -r '.tool_input.old_string // empty')
  new_string=$(echo "$input" | "$JQ" -r '.tool_input.new_string // empty')
  replace_all=$(echo "$input" | "$JQ" -r '.tool_input.replace_all // false')
  # An Edit against a file that isn't on disk yet can't be reconstructed.
  [ -f "$file_path" ] || exit 0
  after_content=$(python3 -c "import sys, json
d = json.load(sys.stdin)
count = -1 if d['all'] else 1
print(d['before'].replace(d['old'], d['new'], count), end='')" <<<"$("$JQ" -n \
    --arg before "$before_content" \
    --arg old "$old_string" \
    --arg new "$new_string" \
    --argjson all "$replace_all" \
    '{before:$before, old:$old, new:$new, all:$all}')") || exit 0
fi

before_tmp=$(mktemp)
after_tmp=$(mktemp)
trap 'rm -f "$before_tmp" "$after_tmp"' EXIT
printf '%s' "$before_content" > "$before_tmp"
printf '%s' "$after_content"  > "$after_tmp"

result=$(node "$HOOK_LIB/test-id-scan.js" "$before_tmp" "$after_tmp" 2>/dev/null) || exit 0
[ -n "$result" ] || exit 0

untagged_count=$(echo "$result" | "$JQ" -r '.untagged | length')
dup_count=$(echo "$result" | "$JQ" -r '.duplicates | length')
[ "$untagged_count" = "0" ] && [ "$dup_count" = "0" ] && exit 0

offenders=$(echo "$result" | "$JQ" -r '
  ([.untagged[] | "  • no ID: \"" + . + "\""]
   + [.duplicates[] | "  • duplicate ID " + .id + ": " + (.titles | join(" / "))])
  | .[0:6] | join("\n")')

headline="test-id-compliance-gate: this write adds test case(s) without a stable test ID"
[ "$untagged_count" = "0" ] && headline="test-id-compliance-gate: this write introduces a duplicate test ID"

reason="[BLOCKED] $headline

──────────────────────────
Do this instead:
──────────────────────────
  Option A — the case is new: give it an ID as the first token of the title
    test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => { … });
    Shape: TC + up to three more letters of area code (2-5 letters total), a
    dash, and a 4-6 digit ordinal — TC-0042, TCLG-000420, [TCSG-0012] · … .
    A suite on another scheme sets CIVITAS_TEST_ID_PATTERN instead.
  Option B — the ID is already taken in this file: mint the next free one
    grep -ohE 'TC[A-Z]{0,3}-[0-9]{4,6}' $(dirname "$file_path")/*.spec.* | sort -u
    Retired IDs are never reused; take the next ordinal, don't fill a gap.

──────────────────────────
What was wrong:
──────────────────────────
File: $file_path
$offenders

An ID belongs to the scenario, not the wording. Four consumers key on it: a
--grep-targeted run, the bug-evidence/<TEST-ID>/ path (title-derived paths move
the moment a title is reworded, scattering one defect's history across
directories), the per-test rows in self-repair / test-repair / test-catalogue
reports, and every human cross-reference between a journey map, a ticket and a
PR. Titles that already existed untagged in this file are out of scope — the
gate only asks about cases this write creates.

──────────────────────────
If the suite predates the convention — read this:
──────────────────────────
Nothing asks you to retro-fit the whole suite in this edit. Migration is
incremental: this gate scopes itself to newly-added titles, so the file's
existing untagged cases stay writable. Backfill them in a dedicated pass and
record the ID index (tests/e2e/docs/test-ids.md) as you go.

──────────────────────────
How this is supposed to be done — load the skill, don't improvise:
──────────────────────────
  Skill('element-interactions')  → the authoring pipeline that owns this rule;
    its Stage 4b compliance sweep (check 12) is where test identity is verified.
  skills/element-interactions/references/test-identity.md
    §1 the ID convention, its four consumers, and the stability contract
    §2 the @known-defect tag for an intentional red, and its no-rerun contract
  skills/element-interactions/references/stages-protocol.md
    §Stage 4b: API Compliance Review — check 12, the sweep this gate backs
  Skill('bug-discovery') → §Assertion Strategy, for a reproduction test that is
    supposed to fail: it needs an ID *and* the @known-defect tag.
  Skill('test-catalogue') → renders the ID as the row identifier, which is what
    makes a catalogue citable."

emit_deny "$reason$(achilles_scope_notice)"
exit 0
