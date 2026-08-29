#!/bin/bash
# 46-reviewer-round42.sh — regressions for round 42 of independent
# adversarial review.
#
# Self-protection screens a command's ARGV for the protected path:
# redirect targets, mutate verbs, flag operands. Round 42 pointed out
# that the kernel owns a program whose argv never names the manifest and
# which writes it anyway — its own CLI.
#
#     kernel-mandate import src/evil.km.json --activate      ->  ALLOW
#
# The reviewer built the bundle with `kernel-mandate export`, which computes
# a VALID fingerprint — so that check is no obstacle to anyone authoring
# the whole bundle — placed it inside a role's own write scope, and ran
# the import. A role scoped to `write: ["src/**"]` rewrote itself to
# `write: ["**"]` with `bash.unrestricted: true`. `--activate` also
# wipes the state directory, which the same axis lists as protected.
# `kernel-mandate use <name>` is quieter still: its operand is a library
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
# the kernel-mandate binary or a bare interpreter — which is why `validate`
# now warns about both. An operator writing `^node\b` into a command
# group is writing a manifest-rewrite channel, and nothing said so.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-42 regressions"

R42=$(mktemp -d)
P="$R42/proj"
mkdir -p "$P/.claude" "$P/src"
export KERNEL_MANDATE_STATE_DIR="$R42/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r42",
  "settings": { "mainSessionRole": "dev" },
  "commandGroups": { "tooling": ["^kernel-mandate\\b", "^(npx|node)\\b", "^echo\\b"] },
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
printf 'dev\n' > "$KERNEL_MANDATE_STATE_DIR/agents/dev"

bp() { "$JQ" -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"dev"}'; }

# --- The subcommands that rewrite the root of trust -------------------
for spec in \
  "kernel-mandate import src/evil.km.json --activate|the command that was proven" \
  "kernel-mandate import src/evil.km.json|without --activate, which still writes the library" \
  "kernel-mandate use other-os|use, whose operand is a NAME with no path at all" \
  "kernel-mandate init --template qa-pipeline|init, which seeds a manifest" \
  "npx kernel-mandate import src/x.km.json|through npx" \
  "npx --yes kernel-mandate use other|with a flag in front of the subcommand" \
  "echo hi && kernel-mandate use other|behind a permitted segment" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R42 $label → DENY" "governed by"
done

# --- Calibration: the read-only surface is the point of having a CLI --
for spec in \
  "kernel-mandate validate|validate" \
  "kernel-mandate status|status" \
  "kernel-mandate doctor|doctor" \
  "kernel-mandate explain --role dev --tool Read --path src/a.ts|explain" \
  "kernel-mandate brief --role dev|brief" \
  "kernel-mandate run --role dev -- node src/a.js|the run wrapper" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_allow "$H" "$(bp "$cmd")" "R42 calibration: $label → ALLOW"
done
# Invoking the CLI file through an interpreter is refused a gate earlier,
# as an interpreter construct — a better deny for a stronger reason, and
# worth pinning so a future narrowing of that gate does not silently open
# this one.
assert_deny "$H" "$(bp 'node /opt/kernel-mandate/bin/cli.mjs import src/x')" \
  "R42 invoking the CLI file directly → DENY" "interpreter"

assert_allow "$H" "$(bp 'echo kernel-mandate import is a command you may not run')" \
  "R42 calibration: the subcommand NAME in prose → ALLOW"

# --- And the direct spellings the axis always caught ------------------
# Pinned beside the new gate so the two can never drift apart: the
# finding was that they were the only spellings it caught.
assert_deny "$H" "$("$JQ" -nc '{tool_name:"Write",tool_input:{file_path:"'"$P"'/.claude/kernel-mandate.json",content:"{}"},cwd:"'"$P"'",agent_id:"dev"}')" \
  "R42 writing the manifest directly → DENY" "kernel mandate"
assert_deny "$H" "$(bp 'echo "{}" > .claude/kernel-mandate.json')" \
  "R42 ...and through a redirect → DENY" "kernel mandate"
