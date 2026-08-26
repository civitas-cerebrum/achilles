#!/bin/bash
# 46-reviewer-round42.sh — regressions for round 42 of independent
# adversarial review.
#
# Self-protection screens a command's ARGV for the protected path:
# redirect targets, mutate verbs, flag operands. Round 42 pointed out
# that the kernel owns a program whose argv never names the manifest and
# which writes it anyway — its own CLI.
#
#     harness-os import src/evil.hos.json --activate      ->  ALLOW
#
# The reviewer built the bundle with `harness-os export`, which computes
# a VALID fingerprint — so that check is no obstacle to anyone authoring
# the whole bundle — placed it inside a role's own write scope, and ran
# the import. A role scoped to `write: ["src/**"]` rewrote itself to
# `write: ["**"]` with `bash.unrestricted: true`. `--activate` also
# wipes the state directory, which the same axis lists as protected.
# `harness-os use <name>` is quieter still: its operand is a library
# NAME, so not even the incidental read-scope check has a path to catch.
#
# This is round 15 (curl's write flags), round 31 (npm's postinstall)
# and round 37 (PATH) arriving in the one place where the kernel owns
# BOTH ends — the protected artifact and the program that writes it —
# and the two were never connected. The axis whose entire job is keeping
# the manifest immutable did not know its own tool existed.
#
# Refused by construction rather than by pattern: a governed role does
# not reconfigure the harness that governs it. The read-only
# subcommands are untouched, and so is `run`.
#
# Latent against every shipped config — no bench role or template grants
# the harness-os binary or a bare interpreter — which is why `validate`
# now warns about both. An operator writing `^node\b` into a command
# group is writing a manifest-rewrite channel, and nothing said so.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-42 regressions"

R42=$(mktemp -d)
P="$R42/proj"
mkdir -p "$P/.claude" "$P/src"
export HARNESS_OS_STATE_DIR="$R42/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r42",
  "settings": { "mainSessionRole": "dev" },
  "commandGroups": { "tooling": ["^harness-os\\b", "^(npx|node)\\b", "^echo\\b"] },
  "roles": {
    "dev": {
      "description": "Ordinary tooling grants, of the shape an operator would write.",
      "tools": { "allow": ["Bash", "Write"] },
      "bash": { "groups": ["tooling"] },
      "read": { "allow": ["src/**"] },
      "write": { "allow": ["src/**"] }
    }
  }
}
JSON
printf 'dev\n' > "$HARNESS_OS_STATE_DIR/agents/dev"

bp() { "$JQ" -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"dev"}'; }

# --- The subcommands that rewrite the root of trust -------------------
for spec in \
  "harness-os import src/evil.hos.json --activate|the command that was proven" \
  "harness-os import src/evil.hos.json|without --activate, which still writes the library" \
  "harness-os use other-os|use, whose operand is a NAME with no path at all" \
  "harness-os init --template qa-pipeline|init, which seeds a manifest" \
  "npx harness-os import src/x.hos.json|through npx" \
  "npx --yes harness-os use other|with a flag in front of the subcommand" \
  "echo hi && harness-os use other|behind a permitted segment" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R42 $label → DENY" "governed by"
done

# --- Calibration: the read-only surface is the point of having a CLI --
for spec in \
  "harness-os validate|validate" \
  "harness-os status|status" \
  "harness-os doctor|doctor" \
  "harness-os explain --role dev --tool Read --path src/a.ts|explain" \
  "harness-os brief --role dev|brief" \
  "harness-os run --role dev -- node src/a.js|the run wrapper" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_allow "$H" "$(bp "$cmd")" "R42 calibration: $label → ALLOW"
done
# Invoking the CLI file through an interpreter is refused a gate earlier,
# as an interpreter construct — a better deny for a stronger reason, and
# worth pinning so a future narrowing of that gate does not silently open
# this one.
assert_deny "$H" "$(bp 'node /opt/harness-os/bin/cli.mjs import src/x')" \
  "R42 invoking the CLI file directly → DENY" "interpreter"

assert_allow "$H" "$(bp 'echo harness-os import is a command you may not run')" \
  "R42 calibration: the subcommand NAME in prose → ALLOW"

# --- And the direct spellings the axis always caught ------------------
# Pinned beside the new gate so the two can never drift apart: the
# finding was that they were the only spellings it caught.
assert_deny "$H" "$("$JQ" -nc '{tool_name:"Write",tool_input:{file_path:"'"$P"'/.claude/harness-os.json",content:"{}"},cwd:"'"$P"'",agent_id:"dev"}')" \
  "R42 writing the manifest directly → DENY" "harness OS"
assert_deny "$H" "$(bp 'echo "{}" > .claude/harness-os.json')" \
  "R42 ...and through a redirect → DENY" "harness OS"
