#!/bin/bash
# 34-reviewer-round28.sh — regressions for round 28 of independent
# adversarial review.
#
# Round 28 was pointed at the class round 27 opened — not how the kernel
# decides, but every path by which enforcement becomes inapplicable or
# partial — and found the branch whose entire job is to be that floor
# answering "no modelled field, therefore allow".
#
# `unboundAgentPolicy: readonly` holds an agent whose role could not be
# resolved to the UNION of every role's read scope. The deny message and
# its regression test both state that guarantee. The implementation:
#
#     UNBOUND_TARGET=$(… .file_path // .notebook_path // .path // empty)
#     [ -n "$UNBOUND_TARGET" ] || exit 0        <-- ALLOW, no check
#
# Grep and Glob take an OPTIONAL path. Omit it and there is no field to
# read, so the branch exits 0 and the search runs from the project root:
#
#     Grep pattern:"SMTP_PASSWORD"              ALLOW  -> prints .env
#     Grep pattern:"x" path:".env"              DENY   (correct)
#
# The union scope was enforced only when a path happened to be present,
# and the single most ordinary thing a search does routed around it.
#
# Two things make this the most instructive round so far.
#
# First, it is the FOURTH time this project has written the sentence "a
# rule attached to a channel exists once per channel". The rule — no
# path means the root, so scope-check the root — has been on the
# governed Glob|Grep arm since round 1, and round 24 put it on the Bash
# channel. The unbound arm is the third channel and never got a copy.
# So the scan is a FUNCTION now, called by both arms, each rendering its
# own deny. The pattern-traversal check went the same way, because it
# had drifted identically: the unbound arm never had one.
#
# Second, it refutes a note this project wrote about itself. Round 27
# recorded the union scope as latent, "bounded away from the planted
# secrets, leaks nothing here". That was true of the path-bearing
# channel only, and the honest thing is to say so in the file where the
# claim was made.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-28 regressions"

R28=$(mktemp -d)
P="$R28/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/docs/acceptance" "$P/docs/internal"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf '# confidential\n' > "$P/docs/internal/roadmap.md"
printf 'x\n' > "$P/tests/e2e/a.spec.ts"
printf 'x\n' > "$P/docs/acceptance/ac.md"
export HARNESS_OS_STATE_DIR="$R28/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r28",
  "settings": { "mainSessionRole": "inspector", "unboundAgentPolicy": "readonly" },
  "roles": {
    "inspector": {
      "description": "Reads tests.",
      "tools": { "allow": ["Read", "Grep", "Glob"] },
      "read": { "allow": ["tests/**"] }
    },
    "reviewer": {
      "description": "Reads the criteria.",
      "tools": { "allow": ["Read", "Grep", "Glob"] },
      "read": { "allow": ["docs/acceptance/**"] }
    }
  }
}
JSON

# No binding file for this id: this is the unbound state, reached the way
# the design documents — a mixed parallel dispatch whose children the
# kernel cannot identify.
up() { "$JQ" -nc --argjson ti "$1" --arg t "$2" \
  '{tool_name:$t,tool_input:$ti,cwd:"'"$P"'",agent_id:"unresolvable-9931"}'; }

# --- The escape, and every shape of it --------------------------------
assert_deny "$H" "$(up '{"pattern":"SMTP_PASSWORD"}' Grep)" \
  "R28 a no-path Grep is a read of the root → DENY" "outside every role's read scope"
assert_deny "$H" "$(up '{"pattern":"SMTP_PASSWORD","output_mode":"files_with_matches"}' Grep)" \
  "R28 and naming only the FILES that match is the same read → DENY" "outside every role's read scope"
assert_deny "$H" "$(up '{"pattern":"**/*"}' Glob)" \
  "R28 a no-path Glob enumerates the tree → DENY" "outside every role's read scope"
assert_deny "$H" "$(up '{"pattern":"x","path":"'"$P"'/tests","glob":"../../*"}' Grep)" \
  "R28 a pattern that climbs out of the root → DENY" "climbs out of the project root"

# The path-bearing spellings were always right; pin them so a future fix
# to one arm cannot quietly regress the other.
assert_deny "$H" "$(up '{"pattern":"x","path":"'"$P"'/.env"}' Grep)" \
  "R28 the path-bearing spelling still denies → DENY" "outside every role's read scope"
assert_deny "$H" "$(up '{"file_path":"'"$P"'/.env"}' Read)" \
  "R28 and so does Read → DENY" "outside every role's read scope"
assert_deny "$H" "$(up '{"file_path":"'"$P"'/docs/internal/roadmap.md"}' Read)" \
  "R28 the confidential subtree is no role's scope → DENY" "outside every role's read scope"

# --- Calibration: the UNION is a real grant, not a ban ----------------
# An unbound agent may see what SOME role may see. Both halves of the
# union, through both channels.
assert_allow "$H" "$(up '{"file_path":"'"$P"'/tests/e2e/a.spec.ts"}' Read)" \
  "R28 calibration: inside one role's scope → ALLOW"
assert_allow "$H" "$(up '{"file_path":"'"$P"'/docs/acceptance/ac.md"}' Read)" \
  "R28 calibration: inside the OTHER role's scope → ALLOW"
assert_allow "$H" "$(up '{"pattern":"x","path":"'"$P"'/tests"}' Grep)" \
  "R28 calibration: a scoped search → ALLOW"
assert_allow "$H" "$(up '{"pattern":"*.md","path":"'"$P"'/docs/acceptance"}' Glob)" \
  "R28 calibration: a scoped glob → ALLOW"

# --- The governed twin must keep behaving identically ------------------
printf 'inspector\n' > "$HARNESS_OS_STATE_DIR/agents/insp"
gp() { "$JQ" -nc --argjson ti "$1" --arg t "$2" \
  '{tool_name:$t,tool_input:$ti,cwd:"'"$P"'",agent_id:"insp"}'; }
assert_deny "$H" "$(gp '{"pattern":"SMTP_PASSWORD"}' Grep)" \
  "R28 the governed arm still refuses a no-path search → DENY" "outside the role's read scope"
assert_deny "$H" "$(gp '{"pattern":"../../*"}' Glob)" \
  "R28 and still refuses an upward pattern → DENY" "upward-traversal"
assert_allow "$H" "$(gp '{"pattern":"x","path":"'"$P"'/tests"}' Grep)" \
  "R28 calibration: the governed scoped search → ALLOW"
# A governed role is held to ITS scope, not the union — the unbound
# policy is a floor for unknown callers, never a widening for known ones.
assert_deny "$H" "$(gp '{"file_path":"'"$P"'/docs/acceptance/ac.md"}' Read)" \
  "R28 a bound role does not get the union → DENY" "outside the role's read scope"
