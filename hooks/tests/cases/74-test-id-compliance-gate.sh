#!/bin/bash
# Tests for test-id-compliance-gate.sh — every test case carries a stable
# test ID. PreToolUse:Write|Edit. DENY mode.
#
# Allow-side coverage (mandatory for a pattern heuristic): the adjacent
# traffic that must NOT be caught — describe/step titles, a commented-out
# test, an untagged case that already lived in the file, non-spec files, and
# the kill-switch.
H="$HOOK_DIR/test-id-compliance-gate.sh"

tmp_into TMP_SPEC /tmp/test-id-gate-XXXXXX

SPEC="$TMP_SPEC/login.spec.ts"
LEGACY="$TMP_SPEC/legacy.spec.ts"

cat > "$SPEC" <<'EOF'
import { test } from './fixtures/base';

test.describe('Login', () => {
  test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});
});
EOF

cat > "$LEGACY" <<'EOF'
import { test } from './fixtures/base';

test('a case written before the convention existed', async ({ steps }) => {});
EOF

# Payload builder with an Edit shape (payload() has no replace_all key).
edit_payload() {
  "$JQ" -n --arg f "$1" --arg o "$2" --arg n "$3" --argjson all "${4:-false}" \
    '{tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n, replace_all:$all}}'
}

# ---------------------------------------------------------------------------
section "test-id-gate: tool + path filtering"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright test')" "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Read file_path="$SPEC")" "Read a spec → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/base.ts" content="export const x = 1;")" \
  "Write a non-spec .ts → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/notes.md" content="test('no id', () => {})")" \
  "Write a .md that quotes a test() → silent allow"

# ---------------------------------------------------------------------------
section "test-id-gate: compliant writes allowed"
assert_allow "$H" "$(payload tool_name=Write file_path="$SPEC" content="import { test } from './fixtures/base';

test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});
test('TCLG-000002 · MFA is offered before the dashboard', async ({ steps }) => {});")" \
  "new tagged case appended → allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/new.spec.ts" content="test('[TCSG-000012] a decimal employee count is rejected', async ({ steps }) => {});")" \
  "bracketed ID on a brand-new file → allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/setup.setup.ts" content="test('TCST-000001 · resolve an account', async ({ steps }) => {});")" \
  "tagged case in a .setup.ts → allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$SPEC" content="test.describe('Login — rejected attempts @known-defect', () => {
  test.step('fill the form', async () => {});
  test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});
});")" \
  "untagged describe + step titles → allow (the case is the unit of identity)"
assert_allow "$H" "$(payload tool_name=Write file_path="$SPEC" content="import { test } from './fixtures/base';

// test('an idea we parked before writing it', async ({ steps }) => {});
test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});")" \
  "commented-out untagged test → allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$SPEC" content="test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {
  test.skip(browserName === 'firefox', 'not supported yet');
})")" \
  "in-body test.skip(condition, reason) → allow (first arg is not a title)"

# ---------------------------------------------------------------------------
section "test-id-gate: pre-existing untagged cases are out of scope"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEGACY" content="import { test } from './fixtures/base';
import { expect } from '@playwright/test';

test('a case written before the convention existed', async ({ steps }) => {});")" \
  "legacy untagged case carried through an unrelated edit → allow"
assert_allow "$H" "$(edit_payload "$LEGACY" "import { test } from './fixtures/base';" "import { test } from './fixtures/base';
import { expect } from '@playwright/test';")" \
  "Edit that never touches the untagged title → allow"

# ---------------------------------------------------------------------------
section "test-id-gate: writes that ADD an untagged case are denied"
assert_deny "$H" "$(payload tool_name=Write file_path="$SPEC" content="import { test } from './fixtures/base';

test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});
test('a wrong password is rejected', async ({ steps }) => {});")" \
  "appended untagged case → deny" \
  'no ID: "a wrong password is rejected"'
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/fresh.spec.ts" content="test('the dashboard renders', async ({ steps }) => {});")" \
  "brand-new file, untagged case → deny" \
  "without a stable test ID"
assert_deny "$H" "$(edit_payload "$LEGACY" "test('a case written before the convention existed', async ({ steps }) => {});" "test('a case written before the convention existed', async ({ steps }) => {});
test.fail('an unfiled defect reproduces', async ({ steps }) => {});")" \
  "Edit appending an untagged test.fail case → deny" \
  "an unfiled defect reproduces"
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/idonly.spec.ts" content="test('TCLG-000099', async ({ steps }) => {});")" \
  "ID with no behaviour sentence → deny" \
  "no ID"

# ---------------------------------------------------------------------------
section "test-id-gate: duplicate IDs inside one file are denied"
assert_deny "$H" "$(payload tool_name=Write file_path="$SPEC" content="test('TCLG-000001 · valid credentials reach the dashboard', async ({ steps }) => {});
test('TCLG-000001 · an unknown email is rejected', async ({ steps }) => {});")" \
  "same ID twice → deny" \
  "duplicate ID TCLG-000001"

# ---------------------------------------------------------------------------
section "test-id-gate: ID shapes"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/house.spec.ts" content="test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => {});")" \
  "house shape TC + area code + 6 digits → allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/short.spec.ts" content="test('TC-1234 · the dashboard renders', async ({ steps }) => {});")" \
  "two-letter prefix + 4 digits → allow"
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/lower.spec.ts" content="test('tclg-000420 · a wrong password is rejected', async ({ steps }) => {});")" \
  "lowercase ID → deny" \
  "without a stable test ID"
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/journey.spec.ts" content="test('LGN-04 · a wrong password is rejected', async ({ steps }) => {});")" \
  "non-TC journey prefix under the default shape → deny" \
  "without a stable test ID"
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/short-digits.spec.ts" content="test('TCLG-042 · too few digits', async ({ steps }) => {});")" \
  "3-digit ordinal → deny" \
  "without a stable test ID"

section "test-id-gate: CIVITAS_TEST_ID_PATTERN pins one exact shape"
CIVITAS_TEST_ID_PATTERN='^(TC[A-Z]{2}-[0-9]{4,6})' \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/pinned.spec.ts" content="test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => {});")" \
  "pinned pattern, matching ID → allow"
CIVITAS_TEST_ID_PATTERN='^(TC[A-Z]{2}-[0-9]{4,6})' \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/pinned2.spec.ts" content="test('TC-0042 · a wrong password is rejected', async ({ steps }) => {});")" \
  "pinned pattern, ID the default would accept → deny" \
  "without a stable test ID"
CIVITAS_TEST_ID_PATTERN='^(TC[A-Z' \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/pinned3.spec.ts" content="test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => {});")" \
  "unparseable pattern → falls back to the default shape, not a blanket deny"

# ---------------------------------------------------------------------------
section "test-id-gate: kill-switch"
CIVITAS_DISABLE_TEST_ID_GATE=1 \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/fresh.spec.ts" content="test('the dashboard renders', async ({ steps }) => {});")" \
  "CIVITAS_DISABLE_TEST_ID_GATE=1 → silent allow"

# ---------------------------------------------------------------------------
section "test-id-gate: the project's own titleIdPattern drives the shape"
# The documented authoring flow (spec-shape.md §1, the requirement-intake
# skill, and hooks/data/factory-rules.example.json, whose titleIdPattern is
# "^[A-Z]{2,5}-\d{2,3}[a-z]? — ") teaches test('CHK-03 — …'). This gate used to
# enforce the TC house shape with nothing connecting the two, so an agent that
# followed the documentation exactly had its spec write DENIED here — by a gate
# the documentation never mentions, demanding an ID in a scheme the project had
# deliberately replaced. These cases pin the bridge in both directions.
TID_PROJ=$(mktemp -d /tmp/test-id-rules-XXXXXX)
mkdir -p "$TID_PROJ/tests"
cat > "$TID_PROJ/achilles-factory-rules.json" <<'TIDRULES'
{
  "version": 1,
  "rules": {
    "specs.shape": {
      "description": "Every new UI spec traces each test title to a written scenario block.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#specs.shape",
      "action": "Title the test '<ID> — <scenario title>'.",
      "scope": ["tests/**"],
      "titleIdPattern": "^[A-Z]{2,5}-\\d{2,3}[a-z]? — ",
      "scenarioDocs": ["docs/scenarios.md"]
    }
  }
}
TIDRULES

CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/checkout.spec.ts" content="test('CHK-03 — Card: place an order', async ({ steps }) => {});")" \
  "documented titleIdPattern title (CHK-03 — …) → allow"
CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/wallet.spec.ts" content="test('CHK-12a — Wallet: place an order', async ({ steps }) => {});
test('CHK-13 — Wallet: a declined payment is reported', async ({ steps }) => {});")" \
  "titleIdPattern ordinal suffix + a second block id → allow"
CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/untitled.spec.ts" content="test('place an order', async ({ steps }) => {});")" \
  "no id at all, under the project pattern → deny" \
  "without a stable test ID"
CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/empty-id.spec.ts" content="test('CHK-03 — ', async ({ steps }) => {});")" \
  "project pattern matched but no behaviour sentence → deny" \
  "without a stable test ID"
CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/dup.spec.ts" content="test('CHK-03 — Card: place an order', async ({ steps }) => {});
test('CHK-03 — Card: a declined payment is reported', async ({ steps }) => {});")" \
  "duplicate id under a pattern with no capture group → deny" \
  "duplicate ID CHK-03"
# The deny has to quote the shape the PROJECT declared. Quoting the house shape
# at a project on its own scheme tells the agent to break a correct title.
CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/untitled2.spec.ts" content="test('place an order', async ({ steps }) => {});")" \
  "deny names the project's own pattern, not the house shape" \
  "this project pins its own ID pattern"
# Option B's grep only knows the house shape: under a project pattern the deny must not offer it.
CLAUDE_PROJECT_DIR="$TID_PROJ" run_hook "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/untitled4.spec.ts" content="test('place an order', async ({ steps }) => {});")"
OPT_B_REASON="$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_eq "$(grep -cF 'TC[A-Z]{0,3}' <<<"$OPT_B_REASON")" "0" "project pattern → Option B offers no house-shape grep"
assert_eq "$(grep -cF '^[A-Z]{2,5}-\d{2,3}[a-z]? — ' <<<"$OPT_B_REASON")" "1" "project pattern → the deny quotes the active pattern"
run_hook "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/untitled5.spec.ts" content="test('place an order', async ({ steps }) => {});")"
assert_eq "$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason' | grep -cF 'TC[A-Z]{0,3}')" "1" "house shape → Option B keeps the grep"
# The root is the current directory when CLAUDE_PROJECT_DIR is unset or empty.
cd "$TID_PROJ" || exit 1
CLAUDE_PROJECT_DIR= \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/untitled3.spec.ts" content="test('place an order', async ({ steps }) => {});")" \
  "CLAUDE_PROJECT_DIR empty, cwd = project → same verdict, project pattern named" \
  "this project pins its own ID pattern"
cd - >/dev/null || exit 1
# Precedence: an explicit operator override still beats the rule file, and a
# project with no rule file is still on the house shape.
CIVITAS_TEST_ID_PATTERN='^(TC[A-Z]{2}-[0-9]{4,6})' CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_allow "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/pinned.spec.ts" content="test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => {});")" \
  "CIVITAS_TEST_ID_PATTERN overrides the project's titleIdPattern → allow"
CIVITAS_TEST_ID_PATTERN='^(TC[A-Z]{2}-[0-9]{4,6})' CLAUDE_PROJECT_DIR="$TID_PROJ" \
  assert_deny "$H" "$(payload tool_name=Write file_path="$TID_PROJ/tests/pinned2.spec.ts" content="test('CHK-03 — Card: place an order', async ({ steps }) => {});")" \
  "CIVITAS_TEST_ID_PATTERN set → the rule file's pattern is NOT consulted" \
  "without a stable test ID"
assert_deny "$H" "$(payload tool_name=Write file_path="$TMP_SPEC/no-rules.spec.ts" content="test('CHK-03 — Card: place an order', async ({ steps }) => {});")" \
  "no rule file → the house TC shape still applies" \
  "without a stable test ID"
rm -rf "$TID_PROJ"
