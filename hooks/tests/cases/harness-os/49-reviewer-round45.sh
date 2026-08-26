#!/bin/bash
# 49-reviewer-round45.sh — regressions for round 45 of independent
# adversarial review.
#
# Round 45 found a live escape against the SHIPPED grants, with a plain
# coreutils verb sitting in the DEFAULT inspection group of every
# manifest this package ships:
#
#     uniq [OPTION]... [INPUT [OUTPUT]]
#     uniq docs/acceptance/registration.md .claude/harness-os.json
#
# uniq's SECOND POSITIONAL operand is an output file. The write-target
# table models cp/mv/install/rsync/ln/dd/truncate/shred/touch, in-place
# sed/perl/ruby, `sort -o`, tar/zip and shell redirects — a list of the
# verbs somebody remembered — and never named this one. So no write
# check ran, and the manifest then sailed through the READ scan as an
# ordinary readable operand, because the manifest is read-EXEMPT for
# every role by design: it is the law each role is held to.
#
#   The one path the read side is told to wave through is the one path
#   the write side must never miss.
#
# The bench's `inspector` — a role with NO write grants at all — used it
# to overwrite the root of trust. The `composer` got the cleaner
# takeover: author an evil manifest as `tests/e2e/evil.json` (a data
# extension, inside its write scope, so allowed), then `uniq evil.json
# .claude/harness-os.json`.
#
# Round 15 had already inverted this question for FLAGS: a flag operand
# naming a protected path is a write unless the flag is a known reader.
# The inversion was never asked about bare operands. It is one rule for
# both now, run per segment, since the command word is what decides and
# a command word belongs to a segment.
#
# That rewrite also fixed two false positives the whole-command version
# had — `head -5 .claude/harness-os.json` and `tail -n 3 …` were refused
# because `-5` and `-n` are not reader FLAGS, though `head` and `tail`
# have no write flag to worry about at all. The doc argues false
# positives are the more dangerous half; two of them were sitting in the
# axis that guards the manifest.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-45 regressions"

R45=$(mktemp -d)
P="$R45/proj"
mkdir -p "$P/.claude" "$P/docs" "$P/tests/e2e"
printf 'AC-1: the form validates.\n' > "$P/docs/acceptance.md"
export HARNESS_OS_STATE_DIR="$R45/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r45",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": {
    "inspection": ["^(cat|head|tail|grep|rg|jq|sort|uniq|wc|diff|echo)\\b", "^curl\\b", "^tee\\b", "^somefilter\\b"]
  },
  "roles": {
    "inspector": {
      "description": "Reads and inspects. No write grants of any kind.",
      "tools": { "allow": ["Bash", "Read", "Glob", "Grep"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["docs/**", "tests/**"] }
    },
    "composer": {
      "description": "Authors specs under tests/e2e and inspects.",
      "tools": { "allow": ["Bash", "Read", "Write"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["docs/**", "tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": [] }
    }
  }
}
JSON
printf 'inspector\n' > "$HARNESS_OS_STATE_DIR/agents/insp"
printf 'composer\n'  > "$HARNESS_OS_STATE_DIR/agents/comp"

b() { "$JQ" -nc --arg c "$1" --arg a "${2:-insp}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- The escape, in the shapes the reviewer drove ---------------------
assert_deny "$H" "$(b 'uniq docs/acceptance.md .claude/harness-os.json')" \
  "R45 uniq's second POSITIONAL operand is a write → DENY" "harness OS itself"
assert_deny "$H" "$(b 'uniq docs/acceptance.md .claude/settings.json')" \
  "R45 ...including a file that does not exist yet → DENY" "harness OS itself"
assert_deny "$H" "$(b 'uniq docs/acceptance.md .claude/harness-os.state/agents/forged')" \
  "R45 ...and a forged role binding in the state dir → DENY" "harness OS itself"
assert_deny "$H" "$(b 'uniq tests/e2e/evil.json .claude/harness-os.json' comp)" \
  "R45 the composer's two-step takeover, at step two → DENY" "harness OS itself"

# The inversion is the point: it is not about `uniq`. Any command whose
# operands this kernel has never modelled fails closed on arrival.
assert_deny "$H" "$(b 'somefilter docs/acceptance.md .claude/harness-os.json')" \
  "R45 an entirely unmodelled verb → DENY" "harness OS itself"
assert_deny "$H" "$(b 'tee .claude/harness-os.json')" \
  "R45 calibration: tee, which was already refused → DENY" "harness OS itself"
assert_deny "$H" "$(b 'sort -o .claude/harness-os.json docs/acceptance.md')" \
  "R45 calibration: sort -o, the flag form → DENY" "harness OS itself"
assert_deny "$H" "$(b 'curl -D .claude/harness-os.json http://x')" \
  "R45 calibration: round 15's detached curl flag → DENY" "harness OS itself"
assert_deny "$H" "$(b 'curl -D.claude/harness-os.json http://x')" \
  "R45 calibration: ...and its attached spelling → DENY" "harness OS itself"

# --- Reading the manifest is ordinary, and must stay ordinary ---------
# It is the law each role is held to; an axis that refuses to let a role
# read its own grants is a false positive with no attack behind it.
for spec in \
  'cat .claude/harness-os.json|cat' \
  'head -5 .claude/harness-os.json|head with a numeric flag (was a FALSE POSITIVE)' \
  'tail -n 3 .claude/harness-os.json|tail with a detached numeric flag (ditto)' \
  'jq -r .name .claude/harness-os.json|jq' \
  'grep -c roles .claude/harness-os.json|grep' \
  'wc -l .claude/harness-os.json|wc' \
  'diff .claude/harness-os.json docs/acceptance.md|diff, both operands read' \
  'grep --file=.claude/harness-os.json docs/acceptance.md|a reader FLAG, attached' \
  'grep --file .claude/harness-os.json docs/acceptance.md|a reader FLAG, detached' ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_allow "$H" "$(b "$cmd")" "R45 calibration: reading the manifest with $label → ALLOW"
done

# --- And ordinary work that names nothing protected is untouched ------
assert_allow "$H" "$(b 'uniq docs/acceptance.md')" \
  "R45 calibration: uniq on an in-scope file → ALLOW"
assert_allow "$H" "$(b 'uniq docs/acceptance.md tests/e2e/out.txt' comp)" \
  "R45 calibration: ...and writing its output inside the write scope → ALLOW"
assert_allow "$H" "$(b 'sort docs/acceptance.md | uniq -c')" \
  "R45 calibration: a pipeline → ALLOW"
# The first cut of this rule read EVERY operand as a path and re-opened
# a false positive round 2 had already closed: `echo` and `printf` take
# TEXT, not paths, and the redirect scan is what decides where their
# output lands. A self-protection rule that eats `echo see .claude/…`
# is how a manifest acquires bash.unrestricted.
assert_allow "$H" "$(b 'echo see .claude/settings.json > tests/e2e/notes.txt' comp)" \
  "R45 calibration: a protected path MENTIONED as text, written in-scope → ALLOW"
assert_deny "$H" "$(b 'echo x > .claude/settings.json' comp)" \
  "R45 calibration: ...but the redirect itself is still refused → DENY" "harness OS itself"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R45"
