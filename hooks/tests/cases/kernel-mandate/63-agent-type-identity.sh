#!/bin/bash
# 63-agent-type-identity.sh — a subagent's host-supplied agent_type binds
# it to a role, ahead of any transcript tag or dispatch registry.
#
# Every subagent hook payload carries `agent_type`: the name of the agent
# definition the child was dispatched as. The host owns it. The kernel
# read `agent_id` from the same payload for 55 rounds and never this
# field — while `explain` synthesized it into its own fixture. Where a
# role maps to an agent definition, this retires the prose rungs
# (transcript tag scanning, nonces, registry TTLs) as the PRIMARY source
# of identity; they remain as fallback for roles that declare no types.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "agent_type identity (round 59)"

R59=$(mktemp -d)
P="$R59/proj"
mkdir -p "$P/.claude" "$P/modules/a/src" "$P/modules/b" "$P/docs"
echo 'sig' > "$P/modules/b/api.sig"; echo '{}' > "$P/docs/ledger.json"; echo 'S=1' > "$P/.env"
export KERNEL_MANDATE_STATE_DIR="$R59/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "round59",
  "settings": { "mainSessionRole": "orchestrator", "unboundAgentPolicy": "readonly" },
  "roles": {
    "orchestrator": {
      "description": "Dispatches; reads contracts and the ledger.",
      "tools": { "allow": ["Agent", "Read"] },
      "read": { "allow": ["docs/**", "modules/*/api.sig"] },
      "dispatch": ["implementer", "judge"]
    },
    "implementer": {
      "description": "Builds module a.",
      "agentTypes": ["implementer", "factory-implementer"],
      "tools": { "allow": ["Read", "Write"] },
      "read":  { "allow": ["modules/a/**", "modules/b/api.sig"] },
      "write": { "allow": ["modules/a/**"] }
    },
    "judge": {
      "description": "Reads everything in the module; writes a verdict.",
      "agentTypes": ["judge"],
      "tools": { "allow": ["Read", "Write"] },
      "read":  { "allow": ["modules/**", "docs/**"] },
      "write": { "allow": ["docs/verdicts/**"] }
    }
  }
}
JSON
# <agent_id> <agent_type> <tool> <path>
sub() { payload tool_name="$3" file_path="$4" content=x agent_id="$1" agent_type="$2" cwd="$P"; }

# ── The rung: agent_type alone is enough ─────────────────────────────
assert_allow "$H" "$(sub a1 implementer Write "$P/modules/a/src/index.js")" \
  "R59 agent_type=implementer: in-scope write → ALLOW (no tag, no registry, no transcript)"
assert_deny  "$H" "$(sub a1 implementer Write "$P/modules/b/api.sig")" \
  "R59 agent_type=implementer: out-of-scope write → DENY" "write"
assert_deny  "$H" "$(sub a1 implementer Read "$P/.env")" \
  "R59 agent_type=implementer: .env → DENY" "read scope"
assert_allow "$H" "$(sub j1 judge Read "$P/modules/a/src/index.js")" \
  "R59 agent_type=judge: reads the module → ALLOW"
assert_deny  "$H" "$(sub j1 judge Write "$P/modules/a/src/index.js")" \
  "R59 agent_type=judge: writes code → DENY" "write"
assert_allow "$H" "$(sub a2 factory-implementer Write "$P/modules/a/src/x.js")" \
  "R59 a second listed type binds to the same role → ALLOW"

# ── The binding is cached per agent_id, like every other rung ────────
[ -f "$R59/state/agents/a1" ] && assert_eq "$(head -n1 "$R59/state/agents/a1")" "implementer" \
  "R59 the agent_type binding is cached under the agent_id"

# ── An UNDECLARED type falls through to the ladder (here: unbound) ───
assert_deny "$H" "$(sub g1 general-purpose Write "$P/modules/a/src/index.js")" \
  "R59 agent_type not declared by any role: falls to unbound policy → write DENY" ""
assert_allow "$H" "$(sub g1 general-purpose Read "$P/docs/ledger.json")" \
  "R59 ...unbound readonly: a read inside the union scope → ALLOW"
assert_deny "$H" "$(sub g1 general-purpose Read "$P/.env")" \
  "R59 ...unbound readonly: .env outside every scope → DENY" ""

# ── A cached binding is stable against a later, different agent_type ─
# a1 is bound to implementer. A payload for a1 claiming judge must not
# re-bind it; the cache was itself derived from a trusted rung.
assert_deny "$H" "$(sub a1 judge Read "$P/docs/ledger.json")" \
  "R59 cached implementer binding wins over a later agent_type=judge claim → DENY (docs out of implementer scope)" "read scope"

# ── Main session is unaffected ───────────────────────────────────────
assert_deny "$H" "$(payload tool_name=Write file_path="$P/modules/a/src/index.js" content=x agent_type=implementer cwd="$P")" \
  "R59 main session (no agent_id) with a stray agent_type stays the orchestrator → DENY" "orchestrator"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R59"
