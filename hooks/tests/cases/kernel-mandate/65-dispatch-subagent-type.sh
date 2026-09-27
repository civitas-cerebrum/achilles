#!/bin/bash
# 65-dispatch-subagent-type.sh — the dispatch gate checks the host's own
# subagent_type against the role the description names.
#
# The description and the prompt tag are text the DISPATCHER writes.
# `subagent_type` is what the host actually spawns, and rung 2b binds the
# child from the host's agent_type. So a planner forbidden to summon the
# judge wrote description "implementer-x: …" + an implementer tag, passed
# subagent_type "judge", cleared every check, and the host spawned a
# child that bound AS THE JUDGE. A judge reproduced it live. The axis
# existed and was not enforced against the one field the dispatcher
# cannot dress up.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "dispatch checks subagent_type (round 61)"

R61=$(mktemp -d)
P="$R61/proj"; mkdir -p "$P/.claude" "$P/factory"
export KERNEL_MANDATE_STATE_DIR="$R61/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "round61",
  "settings": { "mainSessionRole": "planner" },
  "roles": {
    "planner":     { "description": "May dispatch implementers only.", "agentTypes": ["planner"],
                     "tools": { "allow": ["Agent", "Read"] }, "read": { "allow": ["factory/**"] }, "dispatch": ["implementer"] },
    "implementer": { "description": "Builds.", "agentTypes": ["implementer", "factory-implementer"],
                     "tools": { "allow": ["Read", "Write"] }, "read": { "allow": ["factory/**"] }, "write": { "allow": ["factory/src/**"] } },
    "judge":       { "description": "Grades.", "agentTypes": ["judge"],
                     "tools": { "allow": ["Read", "Write"] }, "read": { "allow": ["factory/**"] }, "write": { "allow": ["factory/verdicts/**"] } }
  }
}
JSON
# d <description> <tagrole> <subagent_type>
d() { payload tool_name=Agent description="$1" prompt="<<kernel-mandate-role: $2#ab12c$RANDOM>>
do the work" cwd="$P" | "$JQ" -c --arg t "$3" '.tool_input.subagent_type = $t'; }

# ── The bypass ───────────────────────────────────────────────────────
assert_deny "$H" "$(d 'implementer-auth: build' implementer judge)" \
  "R61 description says implementer, subagent_type says judge → DENY" "subagent_type"

# ── Calibration ──────────────────────────────────────────────────────
assert_allow "$H" "$(d 'implementer-auth: build' implementer implementer)" \
  "R61 matching type → ALLOW"
assert_allow "$H" "$(d 'implementer-auth: build' implementer factory-implementer)" \
  "R61 an alternate type listed under the same role → ALLOW"
assert_allow "$H" "$(d 'implementer-auth: build' implementer general-purpose)" \
  "R61 a type no role declares is not a claim → ALLOW"
assert_allow "$H" "$(payload tool_name=Agent description='implementer-auth: build' prompt='<<kernel-mandate-role: implementer#ab12c1>>
work' cwd="$P")" \
  "R61 no subagent_type field at all → ALLOW (older hosts)"
# The existing forbidden-target check still fires first for a plain
# forbidden description.
assert_deny "$H" "$(d 'judge-auth: grade' judge judge)" \
  "R61 calibration: forbidden target by description → DENY" "may not dispatch role 'judge'"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R61"
