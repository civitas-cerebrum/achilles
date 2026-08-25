#!/bin/bash
# 16-reviewer-round9.sh — regressions for round 9 of independent
# adversarial review.
#
# Round 9 confirmed round 8's structural change holds, then broke the one
# line round 8 had added beside it — and the finding is the sharpest kind
# there is, because the defect was in the FIX.
#
#   F1  the Edit reconstruction, which screens what a file BECOMES rather
#       than the diff, was gated on file size and FAILED OPEN above the
#       cap. Pad a spec past it and the escape can be assembled from
#       fragments that are each innocent again — the exact blindness
#       reconstruction was added to remove. Proven to the planted
#       secrets. A cap that falls back to screening the fragment is a cap
#       that reinstates the bug; it now fails CLOSED, refusing an Edit it
#       cannot verify, and the threshold is 4 MB because an executable
#       file that large is unusual for reasons beyond this kernel.
#
#   FP1 the `setInputFiles` calibration from round 8 was half-right. It
#       denied any literal starting `../` — but a spec in tests/e2e/
#       referencing a fixture in a sibling tests/fixtures/ MUST write
#       `../fixtures/cv.pdf`, and that resolves squarely inside a
#       `tests/**` read scope. It denied the safe idiom while allowing
#       the genuinely unscoped variable form: wrong in both directions.
#       The literal is now resolved against the file's own directory and
#       held to the read scope, which is what the rule always meant.
#
#   FP2 re-screening the whole reconstructed file means a line that was
#       ALREADY in the file refuses every later edit, and the message
#       told the agent to change what it had just written — useless
#       advice for a line it did not write. The screen now runs on the
#       fragment as well, so it can say which of the two it is.
#
# And one found while fixing FP1, which is worth more than any of them:
# an internal error in the kernel made the kernel FAIL OPEN. `set -u`
# turned an out-of-scope variable into an immediate exit, and an exit
# with no JSON is how this hook says "allow" — so a bug silently disabled
# enforcement. There is now an EXIT trap: anything that is not a
# deliberate decision exits non-zero with an explanation. A gate whose
# failure mode is ALLOW is not a gate. (Covered in scripts/test-cli.mjs,
# which can induce the failure.)

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-9 regressions"

R9=$(mktemp -d)
P="$R9/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/fixtures"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'pdf\n' > "$P/tests/fixtures/cv.pdf"
export HARNESS_OS_STATE_DIR="$R9/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r9",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^npx playwright test\\b"] },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Read", "Write", "Edit"] },
      "bash": { "groups": ["t"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'composer\n' > "$HARNESS_OS_STATE_DIR/agents/composer"
wpay() { "$JQ" -nc --arg f "$1" --arg c "$2" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'",agent_id:"composer"}'; }
epay() { "$JQ" -nc --arg f "$1" --arg o "$2" --arg n "$3" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n},cwd:"'"$P"'",agent_id:"composer"}'; }

# --- F1: a file too large to verify is refused, not waved through ------
# Generate the >4MB file cheaply — a shell loop with a command
# substitution per line takes minutes and this suite runs on every commit.
{ printf 'const a = 1;\n'; PAD="// $(head -c 100 /dev/zero | tr '\0' 'x')"; \
  yes "$PAD" 2>/dev/null | head -n 45000; } > "$P/tests/e2e/big.spec.ts"
assert_deny "$H" "$(epay "$P/tests/e2e/big.spec.ts" 'const a = 1;' 'const b = 2;')" \
  "F1 an Edit to a >4MB executable file → DENY (cannot verify what it becomes)" "too large for the kernel to verify"

printf 'const a = 1;\n' > "$P/tests/e2e/small.spec.ts"
assert_allow "$H" "$(epay "$P/tests/e2e/small.spec.ts" 'const a = 1;' 'const b = 2;')" \
  "F1 calibration: an ordinary-sized spec is still editable → ALLOW"

# A data file of any size is not code and is not screened.
{ printf 'x\n'; PADT="$(head -c 100 /dev/zero | tr '\0' 'y')"; \
  yes "$PADT" 2>/dev/null | head -n 45000; } > "$P/tests/e2e/big.txt"
assert_allow "$H" "$(epay "$P/tests/e2e/big.txt" 'x' 'z')" \
  "F1 calibration: a large NON-executable file is unaffected → ALLOW"
rm -f "$P/tests/e2e/big.spec.ts" "$P/tests/e2e/big.txt"

# --- FP1: the fixture path is scope-checked, not prefix-matched --------
assert_allow "$H" "$(wpay "$P/tests/e2e/f1.spec.ts" 'await page.setInputFiles("#cv", "../fixtures/cv.pdf");')" \
  "FP1 a sibling fixture via '../fixtures/' resolves INTO the read scope → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/f2.spec.ts" 'await page.setInputFiles("#cv", "./fixtures/cv.pdf");')" \
  "FP1 the './' form → ALLOW"
assert_deny "$H" "$(wpay "$P/tests/e2e/f3.spec.ts" 'await page.setInputFiles("#f", "../../.env");')" \
  "FP1 but a literal that resolves OUT of the scope → DENY" "outside this role's read scope"
assert_deny "$H" "$(wpay "$P/tests/e2e/f4.spec.ts" 'await page.setInputFiles("#f", "/etc/passwd");')" \
  "FP1 an absolute path outside the scope → DENY" "outside this role's read scope"
assert_deny "$H" "$(wpay "$P/tests/e2e/f5.spec.ts" 'await testInfo.attach("x", { path: "../../.env" });')" \
  "FP1 attach({path}) is resolved the same way → DENY" "outside this role's read scope"
assert_allow "$H" "$(wpay "$P/tests/e2e/f6.spec.ts" 'await testInfo.attach("shot", { body: await page.screenshot() });')" \
  "FP1 attach with a body and no path reads nothing → ALLOW"

# --- FP2: say WHOSE line it is ----------------------------------------
printf 'const d = require("dotenv");\nconst a = 1;\n' > "$P/tests/e2e/pre.spec.ts"
assert_deny "$H" "$(epay "$P/tests/e2e/pre.spec.ts" 'const a = 1;' 'const a = 2;')" \
  "FP2 an unrelated edit to a file that already offends → DENY, saying so" "the file already contains it"
printf 'const a = 1;\n' > "$P/tests/e2e/fresh.spec.ts"
assert_deny "$H" "$(epay "$P/tests/e2e/fresh.spec.ts" 'const a = 1;' 'const d = require("dotenv");')" \
  "FP2 but an edit that INTRODUCES it must not blame the file" "not in this role's declared import list"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R9"
