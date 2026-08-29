#!/bin/bash
# 18-reviewer-round11.sh — regressions for round 11 of independent
# adversarial review.
#
# Round 11 went back to the read-token scan — attacked in rounds 1 through
# 7 and thought settled — and found that the exemption machinery could be
# aimed at a file rather than merely fail to cover one.
#
#   F1  `jq`'s first positional operand is a FILTER, not a file, so the
#       scan exempts it. Which operand that is depends on how many
#       operands each preceding option consumes, and the table had
#       `--rawfile` and `--slurpfile` — both of which take NAME and FILE
#       — grouped with the one-operand options. The scan skipped the
#       NAME, mistook the FILE for the filter, and exempted it.
#
#         jq -n --rawfile x .env '$x'
#
#       reads any file the process can open, into the context of a role
#       scoped to tests/**. Every other axis worked perfectly: the
#       filter is single-quoted, so no shell expansion occurs and the
#       var-expansion rule has nothing to catch; `cat .env`, `jq . .env`
#       and `jq --argfile x .env` all still denied. The miscount was the
#       entire escape.
#
#       The same line was wrong in two more ways that had not been
#       exploited: `--args`/`--jsonargs` take no operand and were eating
#       one, and `--indent` was grouped with two-operand options.
#
# The lesson is about which way an error leans. A scan that fails to
# recognise a file leaves it checked, and the worst case is a false
# deny. A scan that mis-identifies which token is exempt hands the
# exemption to whatever the miscount points at — so arity bugs in this
# block are not cosmetic, they are grants. The two questions are now
# asked separately for every option: how many operands does it consume,
# and is any of them a path the tool will OPEN. An operand is exempted
# only when it is provably not a path.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-11 regressions"

R11=$(mktemp -d)
P="$R11/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/data"
printf 'SMTP_PASSWORD=hunter2\nSTRIPE_KEY=sk_test_51Hxyz\n' > "$P/.env"
printf '{"a":1}\n' > "$P/tests/data/seed.json"
printf '{"b":2}\n' > "$P/tests/e2e/x.json"
printf 'outside\n' > "$R11/outside.txt"
export KERNEL_MANDATE_STATE_DIR="$R11/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r11",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^jq\\b", "^cat\\b", "^ls\\b"] },
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

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'inspector\n' > "$KERNEL_MANDATE_STATE_DIR/agents/inspector"
bpay() { "$JQ" -nc --arg c "$1" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"inspector"}'; }

# --- F1: a two-operand option must not donate its FILE to the filter ---
assert_deny "$H" "$(bpay "jq -n --rawfile x .env '\$x'")" \
  "F1 --rawfile's FILE operand is scope-checked, not exempted as the filter" \
  "outside the role's read scope"
assert_deny "$H" "$(bpay "jq -n --slurpfile x .env '\$x'")" \
  "F1 --slurpfile likewise" "outside the role's read scope"
assert_deny "$H" "$(bpay "jq -n --rawfile x $R11/outside.txt '\$x'")" \
  "F1 an absolute path through --rawfile → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay "jq -n --rawfile x ../outside.txt '\$x'")" \
  "F1 a traversal through --rawfile → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay "jq -n --arg a 1 --rawfile x .env '\$x'")" \
  "F1 preceded by a genuine two-operand option → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay "jq -n --slurpfile a .env --slurpfile b .env '\$a'")" \
  "F1 two file-taking options in one command → DENY" "outside the role's read scope"

# --- calibration: the filter is still exempt, and non-path operands too -
# This block exists because `jq .` was denied once for resolving to the
# cwd. Closing an escape by re-denying the commonest command in the
# mandate would trade one defect for a worse one.
assert_allow "$H" "$(bpay "jq . tests/e2e/x.json")" \
  "calibration: a bare filter over an in-scope file → ALLOW"
assert_allow "$H" "$(bpay "jq -n --rawfile x tests/data/seed.json '\$x'")" \
  "calibration: --rawfile of an IN-scope file → ALLOW (checked, and it passes)"
assert_allow "$H" "$(bpay "jq --arg k .env -n '\$k'")" \
  "calibration: --arg's VALUE is a string jq never opens, even spelled like a path → ALLOW"
assert_allow "$H" "$(bpay "jq --argjson n 1 -n '\$n'")" \
  "calibration: --argjson's two operands → ALLOW"
assert_allow "$H" "$(bpay "jq --indent 2 . tests/e2e/x.json")" \
  "calibration: --indent takes one non-path operand → ALLOW"
assert_allow "$H" "$(bpay "jq --args -n '\$ARGS.positional' a b")" \
  "calibration: --args takes no operand at all → ALLOW"
assert_allow "$H" "$(bpay "jq -r '.b' tests/e2e/x.json")" \
  "calibration: a quoted filter with a leading dot → ALLOW"

# -f/--from-file's operand IS a file and must stay checked — the one
# entry in the table that was already right, pinned so it stays that way.
printf '.b\n' > "$P/tests/data/f.jq"
assert_allow "$H" "$(bpay "jq -f tests/data/f.jq tests/e2e/x.json")" \
  "calibration: -f reading an in-scope filter file → ALLOW"
assert_deny "$H" "$(bpay "jq -f ../outside.txt tests/e2e/x.json")" \
  "F1 but -f pointed out of scope stays DENY" "outside the role's read scope"

# --- self-probe: the siblings round 11 predicted -----------------------
# Round 11's report ended by warning that hand-enumerating each tool's
# argument grammar is a game the read scan keeps losing. Auditing the
# other tables for the same class turned up two more, both of which read
# a real file outside the scope.
#
# The first is the same defect from the other side. `--file=.env` was
# caught, because a flag carrying its value after `=` already has that
# value scope-checked; the ATTACHED short form has no `=` to notice, so
# the whole token was skipped as a flag and the file was never presented
# for checking at all. `grep -f.env <file>` reads .env as a pattern list
# and echoes any line that matches, which turns it into a working oracle
# for the file's contents.
cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r11b",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^grep\\b", "^sed\\b", "^awk\\b", "^dd\\b", "^cat\\b"] },
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
printf 'x\n' > "$P/tests/e2e/a.txt"

assert_deny "$H" "$(bpay 'grep -f.env tests/e2e/a.txt')" \
  "self-probe an attached-value file flag (grep -f.env) → DENY" \
  "outside the role's read scope"
assert_deny "$H" "$(bpay 'sed -f.env tests/e2e/a.txt')" \
  "self-probe sed -f.env → DENY" "outside the role's read scope"
assert_deny "$H" "$(bpay 'awk -f.env tests/e2e/a.txt')" \
  "self-probe awk -f.env → DENY" "outside the role's read scope"

# Stripping the flag letter must not start denying ordinary commands.
# The remainder of `-rn` is not a file, so nothing exists at it; the
# handful of flags whose attached value is a PATTERN are named in the
# kernel and left alone, which is what these pin.
assert_allow "$H" "$(bpay 'grep -rn foo tests')" \
  "self-probe calibration: a clustered short flag → ALLOW"
assert_allow "$H" "$(bpay 'grep -e.env tests/e2e/a.txt')" \
  "self-probe calibration: grep -e's attached value is a PATTERN, not a path → ALLOW"
assert_allow "$H" "$(bpay 'sed -e s/a/b/ tests/e2e/a.txt')" \
  "self-probe calibration: sed -e likewise → ALLOW"
assert_allow "$H" "$(bpay 'awk -v x=1 {print} tests/e2e/a.txt')" \
  "self-probe calibration: awk -v carries a variable, not a file → ALLOW"
assert_allow "$H" "$(bpay 'grep -f tests/e2e/a.txt tests/e2e/a.txt')" \
  "self-probe calibration: -f pointed IN scope, separated form → ALLOW"

# The second wears the other disguise available in this scan: `dd`'s
# operands are spelled NAME=value, which the token pass skips as an
# environment assignment. Two of dd's are paths.
assert_deny "$H" "$(bpay 'dd if=.env')" \
  "self-probe dd's if= operand is a path, not an env assignment → DENY" \
  "outside the role's read scope"
assert_allow "$H" "$(bpay 'grep -rn PLAYWRIGHT_BROWSERS_PATH=/opt tests')" \
  "self-probe calibration: a genuine NAME=value operand is still not a read → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R11"
