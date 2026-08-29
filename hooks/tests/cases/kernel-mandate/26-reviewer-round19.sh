#!/bin/bash
# 26-reviewer-round19.sh — regressions for round 19 of independent
# adversarial review.
#
#   F1  `python3 -c'print(open(".env").read())' README.md`
#
#       Two screens, each correct against its own tests, and the escape
#       is the seam between them. The cluster regex required the code
#       flag to end at whitespace, `=` or end-of-string — but `-c` takes
#       its value ATTACHED, so the next character is a quote and the
#       regex never fired. Round 18's stdin backstop would still have
#       caught it, except that appending any existing file as a decoy
#       operand satisfies "this invocation has a script", and python
#       passes that file harmlessly into sys.argv while running the -c
#       code.
#
# This is the SIXTH time an exact-versus-attached spelling has defeated
# a check here: `grep -f.env` (read scan), `sort -oFILE` (write
# targets), `tar -cf` (archives), round 17's `-Ic` cluster, round 12's
# `curl -d@file`, and now the code flag's own value. Five of those were
# fixed by widening one pattern. The sixth is being fixed by not using a
# pattern.
#
# Each interpreter's short options fall into three kinds — booleans,
# options that consume a value, and options whose value IS code — and
# the kernel now walks the cluster left to right against a per-
# interpreter table of the three. That distinction is not cosmetic:
# `-E` is CODE for perl and a BOOLEAN for python, so any single shared
# letter class must either refuse `python3 -sE script.py` or miss
# `perl -E 'say …'`. The regex it replaces did both at different times.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-19 regressions"

R19=$(mktemp -d)
P="$R19/proj"
mkdir -p "$P/.claude" "$P/tests"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'print(1)\n' > "$P/tests/a.py"
printf '# readme\n' > "$P/README.md"
export KERNEL_MANDATE_STATE_DIR="$R19/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r19",
  "settings": { "mainSessionRole": "analyst" },
  "commandGroups": { "run": ["^python3?\\b", "^node\\b", "^perl\\b", "^ruby\\b"] },
  "roles": {
    "analyst": {
      "description": "Runs project scripts and reads the test tree.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["run"] },
      "read": { "allow": ["tests/**", "README.md"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'analyst\n' > "$KERNEL_MANDATE_STATE_DIR/agents/analyst"
bpay() { "$JQ" -nc --arg c "$1" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"analyst"}'; }

# --- F1: the code flag's value may be attached ------------------------
assert_deny "$H" "$(bpay 'python3 -c'"'"'print(open(".env").read())'"'"' README.md')" \
  "F1 -c'CODE' with a decoy file operand → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -c'"'"'print(1)'"'"'')" \
  "F1 -c'CODE' with no decoy at all → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'perl -e'"'"'print 1'"'"' README.md')" \
  "F1 perl -e'CODE' → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'node -e'"'"'1'"'"' README.md')" \
  "F1 node -e'CODE' → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'ruby -e'"'"'p 1'"'"' README.md')" \
  "F1 ruby -e'CODE' → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -Ic'"'"'print(1)'"'"' README.md')" \
  "F1 attached AND clustered together → DENY" "interpreter one-liner"

# --- the letter's meaning is per-interpreter --------------------------
# The crux of why a regex could not do this. `-E` is code for perl and a
# boolean for python; one shared class must get one of them wrong.
assert_deny "$H" "$(bpay 'perl -E '"'"'say 1'"'"'')" \
  "perl -E is CODE → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'perl -E'"'"'say 1'"'"'')" \
  "perl -E attached → DENY" "interpreter one-liner"
assert_allow "$H" "$(bpay 'python3 -E tests/a.py')" \
  "python3 -E is a BOOLEAN (ignore env vars) → ALLOW"
assert_allow "$H" "$(bpay 'python3 -EsS tests/a.py')" \
  "python3 -EsS, three booleans → ALLOW"
assert_deny "$H" "$(bpay 'ruby -r'"'"'x'"'"' tests/a.py')" \
  "ruby -r preloads a library → DENY" "running or preloading a module"
assert_allow "$H" "$(bpay 'python3 -r tests/a.py')" \
  "but python has no -r, so it is not code there → ALLOW"

# --- a value-taking flag must not be read as code ---------------------
assert_allow "$H" "$(bpay 'python3 -Xdev tests/a.py')" \
  "python3 -Xdev: X consumes the rest, and X is not code → ALLOW"
assert_allow "$H" "$(bpay 'perl -i.bak tests/a.py')" \
  "perl -i.bak: i consumes its suffix → ALLOW"
assert_allow "$H" "$(bpay 'ruby -Ilib tests/a.py')" \
  "ruby -Ilib: I consumes the path → ALLOW"

# --- rounds 17 and 18 must stay closed --------------------------------
assert_deny "$H" "$(bpay 'python3 -Ic '"'"'print(1)'"'"'')" \
  "round 17: the separated cluster" "interpreter one-liner"
assert_deny "$H" "$(bpay 'perl -ne '"'"'print'"'"'')" \
  "round 17: perl -ne" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -m http.server')" \
  "round 17: module execution" "running or preloading a module"
assert_deny "$H" "$(bpay 'python3 <<< '"'"'print(1)'"'"'')" \
  "round 18: the stdin channel" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3')" \
  "round 18: a bare interpreter" "interpreter one-liner"

# --- and ordinary work is still ordinary ------------------------------
assert_allow "$H" "$(bpay 'python3 tests/a.py')" \
  "calibration: a plain script → ALLOW"
assert_allow "$H" "$(bpay 'python3 -u tests/a.py')" \
  "calibration: -u → ALLOW"
assert_allow "$H" "$(bpay 'python3 -OO tests/a.py')" \
  "calibration: -OO → ALLOW"
assert_allow "$H" "$(bpay 'perl -w tests/a.py')" \
  "calibration: perl -w → ALLOW"
assert_allow "$H" "$(bpay 'python3 --version')" \
  "calibration: --version → ALLOW"

# --- the granularity gap round 18 named, now closed -------------------
# Round 18 pointed out that denying `python3 -m pytest` left a Python
# test role only one way out — permitting `interpreter-inline` — which
# simultaneously re-opened `python3 -c`. Accepting arbitrary authored
# code to get a test runner is not a choice anyone should have to make,
# and it is the shape that gets a permit set too wide and left there.
#
# The two are not the same risk: `-c`/`-e` run a program the AGENT wrote
# on the command line, while `-m`/`-r` run or preload an installed
# module it did not author. They are now separate constructs.
cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r19b",
  "settings": { "mainSessionRole": "plain" },
  "commandGroups": { "run": ["^python3?\\b", "^node\\b", "^perl\\b", "^ruby\\b"] },
  "roles": {
    "plain":    { "description": "Neither.",       "tools": { "allow": ["Bash"] },
                  "bash": { "groups": ["run"] }, "read": { "allow": ["tests/**"] } },
    "tester":   { "description": "Runs pytest.",   "tools": { "allow": ["Bash"] },
                  "bash": { "groups": ["run"], "permit": ["interpreter-module"] },
                  "read": { "allow": ["tests/**"] } },
    "scripter": { "description": "One-liners ok.", "tools": { "allow": ["Bash"] },
                  "bash": { "groups": ["run"], "permit": ["interpreter-inline"] },
                  "read": { "allow": ["tests/**"] } }
  }
}
JSON
printf 'tester\n' > "$KERNEL_MANDATE_STATE_DIR/agents/tester"
printf 'scripter\n' > "$KERNEL_MANDATE_STATE_DIR/agents/scripter"
printf 'plain\n' > "$KERNEL_MANDATE_STATE_DIR/agents/plain"
gpay() { "$JQ" -nc --arg c "$1" --arg a "$2" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

assert_allow "$H" "$(gpay 'python3 -m pytest tests' tester)" \
  "split: a role permitting interpreter-module may run pytest → ALLOW"
assert_deny "$H" "$(gpay 'python3 -c '"'"'print(1)'"'"'' tester)" \
  "split: and still may NOT run authored code" "interpreter one-liner"
assert_allow "$H" "$(gpay 'python3 -c '"'"'print(1)'"'"'' scripter)" \
  "split: the role permitting interpreter-inline may → ALLOW"
assert_deny "$H" "$(gpay 'python3 -m pytest tests' scripter)" \
  "split: and does NOT thereby get module execution" "running or preloading a module"
assert_deny "$H" "$(gpay 'python3 -m pytest tests' plain)" \
  "split: a role permitting neither gets neither" "running or preloading a module"
assert_allow "$H" "$(gpay 'python3 tests/a.py' plain)" \
  "split calibration: a plain script needs no permit at all → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R19"
