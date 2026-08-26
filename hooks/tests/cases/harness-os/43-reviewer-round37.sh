#!/bin/bash
# 43-reviewer-round37.sh — regressions for round 37 of independent
# adversarial review.
#
# Round 36 stated the principle: an allowlist of dangerous things fails
# open on the unknown; an exemption list of safe things fails closed.
# Round 37 was asked to audit the kernel for every place that still
# enumerated the dangerous side, and the first one it found was the arm
# guarding the single most dangerous operation in the file.
#
#     PATH=/tmp/evil:/usr/bin:/bin grep -rn foo tests/     ->  ALLOW
#
# The reviewer put a binary at /tmp/evil/grep and ran the approved
# command. It printed all three planted secrets. One line dissolved the
# command group, the read scope, the write scope and the network scope
# at once, for any role holding Bash and one non-builtin command.
#
# The mechanism is the assignment strip — the only place in this kernel
# where text is REMOVED before every axis runs rather than neutralised
# for one check — guarded by a denylist of names round 23 built from
# `NODE_OPTIONS`. `PATH` was not on it, so the assignment passed as
# data, was deleted, and `grep -rn foo tests/` matched a permitted
# pattern with an in-scope operand. The kernel checked the name; the
# shell ran the file.
#
# `PATH` is the standing proof that the dangerous names cannot be
# enumerated: it is the most ordinary environment variable there is. So
# the screen is INVERTED. A leading assignment is refused unless the
# kernel can show the name is inert — on a built-in list of variables
# that are data for an application, or on the role's own `bash.env`
# list, which is how an operator says "this one, deliberately".
#
# The reviewer's structural line is the one to keep: a command group
# constrains a command's SPELLING and never its RESOLUTION. This is
# round 26 (a tsconfig remaps what an import specifier MEANS) arriving
# on the command axis — the environment remaps what the command word
# means. Any channel that rebinds a name defeats an argv model, which is
# why the answer here is a fail-closed screen and the real answer is a
# fixed environment under `harness-os run`.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-37 regressions"

R37=$(mktemp -d)
P="$R37/proj"
mkdir -p "$P/.claude" "$P/tests"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'x\n' > "$P/tests/a.txt"
export HARNESS_OS_STATE_DIR="$R37/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r37",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "i": ["^(ls|cat|grep|git|echo)\\b"] },
  "roles": {
    "inspector": {
      "description": "Reads tests. One non-builtin command is all it takes.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["i"] },
      "read": { "allow": ["tests/**"] }
    },
    "named": {
      "description": "Names the variables it needs.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["i"], "env": ["APP_URL", "PLAYWRIGHT_BROWSERS_PATH"] },
      "read": { "allow": ["tests/**"] }
    },
    "trusted": {
      "description": "Opted into environment injection wholesale.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["i"], "permit": ["env-injection"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON
for r in inspector named trusted; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done

bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- The command that was proven, and the class it belongs to ---------
assert_deny "$H" "$(bp 'PATH=/tmp/evil:/usr/bin:/bin grep -rn foo tests/')" \
  "R37 the assignment that was proven → DENY" "which FILE a command word runs"
assert_deny "$H" "$(bp 'env PATH=/tmp/evil grep -rn foo tests/')" \
  "R37 ...and through the env wrapper, the second strip → DENY" "which FILE a command word runs"
for spec in \
  "GIT_CONFIG_COUNT=1 git status|git config injected through the environment" \
  "GIT_CONFIG_KEY_0=core.pager git status|its key half" \
  "PAGER=/tmp/evil git log|the pager git spawns" \
  "GIT_SEQUENCE_EDITOR=/tmp/evil git log|the editor it spawns" \
  "MANPAGER=/tmp/evil git log|another name for the same idea" \
  "SHELL=/tmp/evil grep -rn x tests/|which shell a program starts" \
  "IFS=x grep -rn x tests/|how the shell splits words" \
  "FOO=bar grep -rn x tests/|a name nobody can show is data" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R37 $label → DENY" "in front of a command"
done

# --- Calibration: the inert names still work --------------------------
# The inversion is only defensible if the ordinary cases survive it.
for spec in "CI=1|CI" "NODE_ENV=test|NODE_ENV" "TZ=UTC|TZ" "LANG=C|LANG" \
            "NO_COLOR=1|NO_COLOR" "DEBUG=app:*|DEBUG" "HEADLESS=1|HEADLESS"; do
  a="${spec%%|*}"; label="${spec##*|}"
  assert_allow "$H" "$(bp "$a grep -rn x tests/")" \
    "R37 calibration: $label is data for an application → ALLOW"
done
assert_allow "$H" "$(bp 'CI=1 TZ=UTC grep -rn x tests/')" \
  "R37 calibration: several inert names at once → ALLOW"
assert_allow "$H" "$(bp 'grep -rn x tests/')" \
  "R37 calibration: no assignment at all → ALLOW"

# --- The two escape hatches, and their limits -------------------------
assert_allow "$H" "$(bp 'APP_URL=http://localhost:4173 grep -rn x tests/' named)" \
  "R37 a role may name the variable it needs → ALLOW"
assert_allow "$H" "$(bp 'PLAYWRIGHT_BROWSERS_PATH=/opt/pw grep -rn x tests/' named)" \
  "R37 ...including one that picks a binary, said out loud → ALLOW"
# Naming one does not name the others — that is the whole point of
# granularity, and it is what `permit` waives.
assert_deny "$H" "$(bp 'PATH=/tmp/evil grep -rn x tests/' named)" \
  "R37 naming one variable does not name PATH → DENY" "which FILE a command word runs"
assert_allow "$H" "$(bp 'PATH=/tmp/evil grep -rn x tests/' trusted)" \
  "R37 a role that permits env-injection may still do it → ALLOW"

# --- And the axes the assignment used to dissolve still hold ----------
assert_deny "$H" "$(bp 'CI=1 cat .env')" \
  "R37 an inert assignment does not waive the read scope → DENY" "outside the role's read scope"
assert_deny "$H" "$(bp 'CI=1 npm install evil')" \
  "R37 nor the command group → DENY" "matches none"
