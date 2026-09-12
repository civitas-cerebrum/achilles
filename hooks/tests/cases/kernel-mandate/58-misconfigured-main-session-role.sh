#!/bin/bash
# 58-misconfigured-main-session-role.sh — a named role that does not
# resolve is a MISCONFIGURATION, and it fails closed.
#
# The defect this pins: rung 1 of kernel_mandate_resolve_role folded two
# different facts into one silent-allow branch —
#
#   settings.mainSessionRole absent   → ungoverned on purpose  (correct)
#   settings.mainSessionRole = typo   → ungoverned by accident (the bug)
#
# `"orchestratorr"` against an otherwise-correct mandate produced exit 0,
# zero bytes of stdout, no state directory and therefore NO DECISION LOG,
# for a payload of `rm -rf /`. Every channel an operator consults was
# silent, and `doctor` — the command actually reached for when asking why
# the gate isn't firing — had nothing to read. Only `validate` named it,
# and nothing forces `validate`.
#
# It was also inconsistent with this kernel's own adjacent design: an
# UNPARSEABLE manifest fails closed, so a corrupt file was safer than a
# misspelled name. The manifest held both facts; the branch read one.
#
# Per the allow-test convention: every deny here ships with the
# genuinely-ungoverned shapes it must NOT swallow.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "misconfigured mainSessionRole (round 55)"

R55=$(mktemp -d)
PROJ55="$R55/proj"
mkdir -p "$PROJ55/.claude" "$PROJ55/docs" "$PROJ55/src"
echo '{}' > "$PROJ55/docs/ledger.json"

export KERNEL_MANDATE_STATE_DIR="$R55/state"
export KERNEL_MANDATE_MANIFEST="$PROJ55/.claude/kernel-mandate.json"

# <mainSessionRole spelling>  — writes the manifest and returns nothing.
mk() {
  local setting="$1"
  cat > "$PROJ55/.claude/kernel-mandate.json" <<JSON
{
  "kernelMandateVersion": 1,
  "name": "round55",
  "settings": { ${setting} },
  "roles": {
    "orchestrator": {
      "description": "Dispatches work; acts on nothing itself.",
      "tools": { "allow": ["Agent", "Read"] },
      "read": { "allow": ["docs/**"] },
      "dispatch": ["runner"]
    },
    "runner": {
      "description": "Runs the suite.",
      "tools": { "allow": ["Bash"] },
      "read": { "allow": ["docs/**", "src/**"] }
    }
  }
}
JSON
}

# <command> [tool] — a main-session payload (no agent_id).
p() { payload tool_name="${2:-Bash}" command="$1" cwd="$PROJ55"; }

# ── The bug: a typo must not read as "ungoverned" ────────────────────
mk '"mainSessionRole": "orchestratorr"'
assert_deny "$H" "$(p 'rm -rf /')" \
  "R55 typo'd mainSessionRole + rm -rf / → DENY" "defines no such role"
assert_deny "$H" "$(p 'cat .env')" \
  "R55 typo'd mainSessionRole + cat .env → DENY" "mainSessionRole"
assert_deny "$H" "$(payload tool_name=Write file_path="$PROJ55/src/app.js" content=x cwd="$PROJ55")" \
  "R55 typo'd mainSessionRole + a Write → DENY" "defines no such role"

# The denial has to be actionable: name the bad spelling AND the roles
# that do exist, or the operator is left bisecting a JSON file.
assert_deny "$H" "$(p 'ls')" \
  "R55 the denial names the roles that DO exist" "orchestrator, runner"

# Case matters — role lookup is exact, and a near-miss is still a miss.
mk '"mainSessionRole": "Orchestrator"'
assert_deny "$H" "$(p 'rm -rf /')" \
  "R55 wrong-case mainSessionRole → DENY" "defines no such role"

# A role that exists in a DIFFERENT manifest section is still not a role.
mk '"mainSessionRole": "roles"'
assert_deny "$H" "$(p 'rm -rf /')" \
  "R55 a manifest key that isn't a role name → DENY" "defines no such role"

# ── Calibration: the genuinely-ungoverned shapes still pass through ──
# These are the operator's design surface. Swallowing them would make
# the kernel unusable in every project that only governs subagents.
mk '"unboundAgentPolicy": "readonly"'
assert_allow "$H" "$(p 'rm -rf /tmp/scratch')" \
  "R55 calibration: NO mainSessionRole key → ungoverned on purpose, ALLOW"

mk '"mainSessionRole": ""'
assert_allow "$H" "$(p 'rm -rf /tmp/scratch')" \
  "R55 calibration: empty-string mainSessionRole → ALLOW"

mk '"mainSessionRole": null'
assert_allow "$H" "$(p 'rm -rf /tmp/scratch')" \
  "R55 calibration: null mainSessionRole → ALLOW"

# ── Calibration: a CORRECT name still governs exactly as before ──────
mk '"mainSessionRole": "orchestrator"'
assert_deny "$H" "$(p 'rm -rf /')" \
  "R55 calibration: correct name still governs → DENY" "orchestrator"
assert_allow "$H" "$(payload tool_name=Read file_path="$PROJ55/docs/ledger.json" cwd="$PROJ55")" \
  "R55 calibration: correct name, in-scope read → ALLOW"

# ── The misconfiguration must not out-rank the operator's kill switch ─
# An operator who has switched the kernel off is not asking to be told
# about a typo in a file the kernel is not reading.
mk '"mainSessionRole": "orchestratorr"'
KERNEL_MANDATE=0 assert_allow "$H" "$(p 'rm -rf /')" \
  "R55 KERNEL_MANDATE=0 outranks the misconfiguration → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R55"
