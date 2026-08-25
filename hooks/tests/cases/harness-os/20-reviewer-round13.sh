#!/bin/bash
# 20-reviewer-round13.sh — regressions for round 13 of independent
# adversarial review.
#
#   F1  `jq -f prog.jq .env` exempted the INPUT file from the read scan.
#
#       jq's first positional is a filter, not a path, so it is exempt —
#       without that, `jq . file.json` is denied for a `.` it never
#       opens. But when `-f`/`--from-file` supplies the filter there is
#       no positional filter, and the first positional is an input FILE.
#       The block skipped past the program file, reached `.env`, and
#       exempted it as though it were the filter. Every spelling
#       escaped: separated, attached, `=`, and with `-R` in front — and
#       the program file did not even have to exist for the exemption to
#       land on the input.
#
# This is the same defect for the THIRD time, in the third of three
# adjacent blocks. grep was fixed in round 4. sed and awk in round 12.
# jq sat twenty lines from both of them and went thirteen rounds. Three
# reviewers found the same bug in the same `case` statement because each
# block decided for itself whether to exempt its positional, and each
# had to remember the guard independently.
#
# So the fix is not a third guard. The blocks no longer decide: each one
# only REPORTS whether a flag supplied the program and which operand the
# positional program is, and one line after the `esac` makes the
# exemption for all of them. A block added later cannot forget the
# guard, because it no longer writes the line that would forget it.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-13 regressions"

R13=$(mktemp -d)
P="$R13/proj"
mkdir -p "$P/.claude" "$P/tests/data"
printf 'SMTP_PASSWORD=hunter2\nSTRIPE_KEY=sk_test_51Hxyz\n' > "$P/.env"
printf '{"a":1}\n' > "$P/tests/data/page.json"
printf '.\n' > "$P/tests/data/prog.jq"
printf '{print}\n' > "$P/tests/data/prog.awk"
printf 'p\n' > "$P/tests/data/prog.sed"
printf 'foo\n' > "$P/tests/data/pats.txt"
export HARNESS_OS_STATE_DIR="$R13/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r13",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^jq\\b", "^sed\\b", "^awk\\b", "^grep\\b", "^cat\\b"] },
  "roles": {
    "inspector": {
      "description": "Inspects the app surface and reports findings.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["inspect"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'inspector\n' > "$HARNESS_OS_STATE_DIR/agents/inspector"
bpay() { "$JQ" -nc --arg c "$1" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"inspector"}'; }

# --- F1: a filter supplied by flag leaves no positional to exempt -----
assert_deny "$H" "$(bpay 'jq -f tests/data/prog.jq .env')" \
  "F1 jq -f supplies the filter, so .env is an INPUT file → DENY" \
  "outside the role's read scope"
assert_deny "$H" "$(bpay 'jq --from-file tests/data/prog.jq .env')" \
  "F1 the --from-file spelling → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'jq -ftests/data/prog.jq .env')" \
  "F1 the attached -f spelling → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'jq --from-file=tests/data/prog.jq .env')" \
  "F1 the --from-file= spelling → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'jq -R -f tests/data/prog.jq .env')" \
  "F1 with -R in front, the form that reads a non-JSON file → DENY" \
  "outside the role's read scope"
assert_deny "$H" "$(bpay 'jq -f /nope/x.jq .env')" \
  "F1 the program file need not exist for the input to be checked → DENY" \
  "outside the role's read scope"

# Calibration. The exemption is the whole reason this block exists: `jq .`
# resolves to the cwd, and denying it would refuse the most ordinary
# command in any inspection mandate.
assert_allow "$H" "$(bpay 'jq . tests/data/page.json')" \
  "F1 calibration: a bare filter over an in-scope file → ALLOW"
assert_allow "$H" "$(bpay 'jq -r .a tests/data/page.json')" \
  "F1 calibration: a dotted filter → ALLOW"
assert_allow "$H" "$(bpay 'jq -f tests/data/prog.jq tests/data/page.json')" \
  "F1 calibration: -f with an in-scope input → ALLOW"
assert_deny "$H" "$(bpay 'jq -f .env tests/data/page.json')" \
  "F1 and -f's own operand stays checked (round 6) → DENY" \
  "outside the role's read scope"

# --- the class, closed in one place: all three commands agree ---------
# The point of the refactor is that these four now share a single
# decision. If a later change reintroduces the bug in any one of them,
# the whole group fails together rather than one slipping through.
assert_deny "$H" "$(bpay 'grep -e foo .env')" \
  "class grep -e supplies the pattern → the positional is an input → DENY" \
  "outside the role's read scope"
assert_deny "$H" "$(bpay 'sed -e p .env')" \
  "class sed -e likewise → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'awk -f tests/data/prog.awk .env')" \
  "class awk -f likewise → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'grep -f tests/data/pats.txt .env')" \
  "class grep -f likewise → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'sed -f tests/data/prog.sed .env')" \
  "class sed -f likewise → DENY" "outside the role's read scope"

assert_allow "$H" "$(bpay 'grep foo tests/data/page.json')" \
  "class calibration: grep's positional pattern is still exempt → ALLOW"
assert_allow "$H" "$(bpay 'sed p tests/data/page.json')" \
  "class calibration: sed's positional script is still exempt → ALLOW"
assert_allow "$H" "$(bpay 'awk {print} tests/data/page.json')" \
  "class calibration: awk's positional program is still exempt → ALLOW"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R13"
