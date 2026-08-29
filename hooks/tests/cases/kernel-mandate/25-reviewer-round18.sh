#!/bin/bash
# 25-reviewer-round18.sh — regressions for round 18 of independent
# adversarial review.
#
#   F1  every one of these interpreters reads its program from STDIN
#       when handed neither a code flag nor a script:
#
#         python3 <<< 'print(open(".env").read())'
#         echo 'CODE' | node
#         python3            (a bare invocation, then the program)
#
#       so arbitrary code walked past a check that was looking for `-c`.
#
# Round 17 made that check better at recognising flags. Round 18 pointed
# out that being better at recognising flags is no help whatever against
# a command that has none — the two findings are exact opposites, one
# week apart, in the same six lines.
#
# The kernel had already closed this channel one list-entry above, where
# a bare `sh`/`bash` is refused because "its input becomes an unchecked
# script". That sentence was equally true of python, node, perl and ruby
# and had simply never been said about them. It is the same failure this
# document keeps recording under a different name: a rule that is right
# where it was written and was never carried the two lines to its
# neighbour.
#
# A script OPERAND is what distinguishes the safe form, because then the
# program is a file the path scopes already govern. It must be a path
# that EXISTS, or `python3 -X dev` reads its own flag value as a script
# and hands the stdin channel straight back.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-18 regressions"

R18=$(mktemp -d)
P="$R18/proj"
mkdir -p "$P/.claude" "$P/tests"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'print(1)\n' > "$P/tests/a.py"
export KERNEL_MANDATE_STATE_DIR="$R18/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r18",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^python3?\\b", "^node\\b", "^perl\\b", "^ruby\\b", "^echo\\b"] },
  "roles": {
    "inspector": {
      "description": "Runs project scripts.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"] },
      "read": { "allow": ["tests/**"] }
    },
    "trusted": {
      "description": "Explicitly opted in to interpreter one-liners.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"], "permit": ["interpreter-inline"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'inspector\n' > "$KERNEL_MANDATE_STATE_DIR/agents/inspector"
printf 'trusted\n' > "$KERNEL_MANDATE_STATE_DIR/agents/trusted"
bpay() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- F1: no flag is not the same as no code --------------------------
assert_deny "$H" "$(bpay 'python3 <<< '"'"'print(open(".env").read())'"'"'')" \
  "F1 a here-string feeds the program on stdin → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3')" \
  "F1 a bare interpreter reads its program from stdin → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'node')" \
  "F1 node likewise" "interpreter one-liner"
assert_deny "$H" "$(bpay 'perl')" \
  "F1 perl likewise" "interpreter one-liner"
assert_deny "$H" "$(bpay 'ruby')" \
  "F1 ruby likewise" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -')" \
  "F1 the explicit stdin operand → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -X dev')" \
  "F1 a flag VALUE must not be mistaken for a script → DENY" "interpreter one-liner"

# --- calibration: running a script is still running a script ----------
assert_allow "$H" "$(bpay 'python3 tests/a.py')" \
  "calibration: a script operand that exists → ALLOW"
assert_allow "$H" "$(bpay 'python3 -u tests/a.py')" \
  "calibration: with an unrelated flag → ALLOW"
assert_allow "$H" "$(bpay 'perl -w tests/a.py')" \
  "calibration: perl -w with a script → ALLOW"
assert_allow "$H" "$(bpay 'node tests/a.py')" \
  "calibration: node with a script → ALLOW"
assert_allow "$H" "$(bpay 'python3 --version')" \
  "calibration: --version runs no program → ALLOW"
assert_allow "$H" "$(bpay 'node --version')" \
  "calibration: node --version → ALLOW"
assert_allow "$H" "$(bpay 'python3 -V')" \
  "calibration: the short spelling → ALLOW"
assert_allow "$H" "$(bpay 'node --help')" \
  "calibration: --help → ALLOW"

# --- the opt-in still governs both spellings -------------------------
assert_allow "$H" "$(bpay 'python3 <<< '"'"'print(1)'"'"'' trusted)" \
  "a role that permits interpreter-inline may use stdin too → ALLOW"
assert_deny "$H" "$(bpay 'python3 <<< '"'"'print(1)'"'"'')" \
  "and the role beside it may not" "interpreter one-liner"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R18"
