#!/bin/bash
# 33-reviewer-round27.sh — regressions for round 27 of independent
# adversarial review.
#
# Twenty-six rounds of work on how the kernel DECIDES, and round 27
# attacked whether it decides at all. It is the most serious finding in
# the series, and it required no adversary.
#
# The manifest was located by a POINT LOOKUP keyed on git:
#
#     HOS_ROOT=$(git rev-parse --show-toplevel || echo "$HOS_CWD")
#     HOS_MANIFEST="$HOS_ROOT/.claude/harness-os.json"
#     [ -f "$HOS_MANIFEST" ] || return 1     ->  exit 0  ->  ALLOW
#
# Not-found means "this project never opted in", which means ALLOW. So a
# wrong answer here denies nothing and silently ungoverns everything:
# no deny, no warning, no line in the decision log. And the lookup bets
# that repo-root equals project-root — an assumption documented nowhere
# as a requirement, and false for the two most ordinary ways code sits
# on disk. Both were demonstrated against the benchmark's own manifest:
#
#   A1  a governed project checked out INSIDE a larger repo. git answers
#       with the outer root, the manifest is not there, and the whole
#       kernel switches off. The REVIEWER — a role with no write grants
#       at all — was allowed to overwrite the manifest itself. The root
#       of trust, rewritable by the most restricted role in the file,
#       not by defeating a check but by making every check unreachable.
#
#   A2  a non-git project with cwd one directory below the root. Same
#       silence.
#
# Round 10 swept "is this kernel applicable here?" and fixed four
# instances — a nonexistent cwd, a relative cwd, a missing jq, an
# unimplemented manifest version. This is the fifth, and the only one
# needing nothing but ordinary project placement.
#
# Discovery walks UP now, the way every other tool finds its own config,
# and the directory holding the first `.claude/harness-os.json` IS the
# project root — so the root is a consequence of where the law is,
# instead of a guess that the law will be where git says.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-27 regressions"

R27=$(mktemp -d)
export HARNESS_OS_STATE_DIR="$R27/state"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'reviewer\n'  > "$HARNESS_OS_STATE_DIR/agents/rev"
printf 'inspector\n' > "$HARNESS_OS_STATE_DIR/agents/insp"

MANIFEST_BODY='{
  "harnessOsVersion": 1,
  "name": "r27",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "i": ["^(ls|cat|grep|echo)\\b"] },
  "roles": {
    "inspector": {
      "description": "Reads tests only.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["i"] },
      "read": { "allow": ["tests/**"] }
    },
    "reviewer": {
      "description": "Reads the criteria and the deliverable. No write grants at all.",
      "tools": { "allow": ["Read"] },
      "read": { "allow": ["docs/acceptance/**"] }
    }
  }
}'

mk_project() {  # mk_project <dir>
  mkdir -p "$1/.claude" "$1/tests/e2e" "$1/docs/acceptance" "$1/src"
  printf '%s\n' "$MANIFEST_BODY" > "$1/.claude/harness-os.json"
  printf 'ADMIN_TOKEN=tok_9f8e7d\n' > "$1/.env"
  printf 'x\n' > "$1/docs/acceptance/ac.md"
}

rp() { "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "${3:-rev}" \
  '{tool_name:"Read",tool_input:{file_path:$f},cwd:$c,agent_id:$a}'; }
wp() { "$JQ" -nc --arg f "$1" --arg c "$2" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:"{}"},cwd:$c,agent_id:"rev"}'; }
bp() { "$JQ" -nc --arg x "$1" --arg c "$2" \
  '{tool_name:"Bash",tool_input:{command:$x},cwd:$c,agent_id:"insp"}'; }

# HARNESS_OS_MANIFEST would pin the answer and hide the bug, which is
# the whole point of this file — discovery has to do the work.
unset HARNESS_OS_MANIFEST

# --- A2: cwd BELOW the project root -----------------------------------
PLAIN="$R27/plain"
mk_project "$PLAIN"
for sub in "" tests tests/e2e docs src; do
  cwd="$PLAIN${sub:+/$sub}"
  assert_deny "$H" "$(rp "$PLAIN/.env" "$cwd")" \
    "A2 reviewer reads .env from cwd '${sub:-<root>}' → DENY" "outside the role's read scope"
done
assert_allow "$H" "$(rp "$PLAIN/docs/acceptance/ac.md" "$PLAIN/tests/e2e")" \
  "A2 calibration: the criteria are still readable from a subdirectory → ALLOW"
assert_deny "$H" "$(bp 'cat ../../.env' "$PLAIN/tests/e2e")" \
  "A2 and the Bash channel is governed from down there too → DENY" "outside the role's read scope"

# --- A1: the project lives inside a larger repo ------------------------
MONO="$R27/mono"
mkdir -p "$MONO/services"
( cd "$MONO" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
QA="$MONO/services/qa"
mk_project "$QA"
if [ -d "$MONO/.git" ]; then
  assert_deny "$H" "$(rp "$QA/.env" "$QA")" \
    "A1 a project inside a repo is still governed → DENY" "outside the role's read scope"
  # The one that says what the bug really was: a role with NO write
  # grants was allowed to rewrite the law it is held to.
  assert_deny "$H" "$(wp "$QA/.claude/harness-os.json" "$QA")" \
    "A1 the reviewer may not overwrite the manifest → DENY" "harness OS"
  assert_deny "$H" "$(rp "$QA/.env" "$QA/tests/e2e")" \
    "A1 nor from a subdirectory of it → DENY" "outside the role's read scope"
  assert_allow "$H" "$(rp "$QA/docs/acceptance/ac.md" "$QA")" \
    "A1 calibration: its own scope still works → ALLOW"
else
  # No git here: A1 cannot be staged, and a test that silently vanishes
  # is worse than one that says so.
  echo "  · A1 skipped: git is not available to build the outer repo"
fi

# --- The opt-in must survive: no manifest anywhere is still ALLOW ------
UNGOV="$R27/ungoverned/deep/deeper"
mkdir -p "$UNGOV"
printf 'x\n' > "$R27/ungoverned/secret.txt"
assert_allow "$H" "$(rp "$R27/ungoverned/secret.txt" "$UNGOV")" \
  "opt-in intact: a project with no manifest is ungoverned → ALLOW"

# --- The nearest manifest wins ----------------------------------------
# A nested project has its own law, and the walk must stop at the first
# one rather than running to the outermost.
NEST="$PLAIN/tests/nested"
mkdir -p "$NEST/.claude" "$NEST/tests"
printf '%s\n' '{
  "harnessOsVersion": 1,
  "name": "r27-nested",
  "settings": { "mainSessionRole": "reviewer" },
  "roles": {
    "reviewer": {
      "description": "Here the reviewer may read anything in the nested project.",
      "tools": { "allow": ["Read"] },
      "read": { "allow": ["**"] }
    }
  }
}' > "$NEST/.claude/harness-os.json"
printf 'x\n' > "$NEST/anything.txt"
assert_allow "$H" "$(rp "$NEST/anything.txt" "$NEST")" \
  "the NEAREST manifest governs, not the outermost → ALLOW"
assert_deny "$H" "$(rp "$PLAIN/.env" "$PLAIN/tests")" \
  "and one directory up, the outer manifest is back in force → DENY" "outside the role's read scope"

# --- Agent-id collisions (round 27's latent note) ---------------------
# Two ids that differ only in a character the sanitiser replaces must not
# share one binding file, or one agent inherits the other's role.
printf 'reviewer\n' > "$HARNESS_OS_STATE_DIR/agents/$(printf 'a_b')"
assert_deny "$H" "$(rp "$PLAIN/.env" "$PLAIN" 'a/b')" \
  "an id needing sanitisation does not inherit a lookalike's binding → DENY" "harness-OS role could not be resolved"
