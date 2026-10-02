#!/bin/bash
# 61-control-surfaces.sh — `.claude/agents/` and `.mcp.json` are
# self-protected on every channel.
#
# An agent definition is what a role IS once identity binds to the
# host's agent_type; `.mcp.json` registers tool servers. A reviewer with
# a broad write grant wrote `.claude/agents/evil.md` and the kernel —
# which refused `.claude/settings.json` on the same call — let it
# through. The file that redefines the judge was less protected than the
# file that registers the hook.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "control surfaces: .claude/agents and .mcp.json (round 57)"

R57b=$(mktemp -d)
P="$R57b/proj"
mkdir -p "$P/.claude/agents" "$P/src" "$P/tests/e2e/.claude/agents"
echo 'x' > "$P/.claude/agents/judge.md"; echo '{}' > "$P/.mcp.json"
export KERNEL_MANDATE_STATE_DIR="$R57b/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "round57b",
  "settings": { "mainSessionRole": "broad" },
  "roles": {
    "broad": {
      "description": "Deliberately over-granted: write everything, run anything.",
      "tools": { "allow": ["Read", "Write", "Edit", "Bash"] },
      "read":  { "allow": ["**"] },
      "write": { "allow": ["**"] },
      "bash":  { "unrestricted": true }
    }
  }
}
JSON
wr() { payload tool_name=Write file_path="$1" content=x cwd="$P"; }
ed() { payload tool_name=Edit file_path="$1" old_string=a new_string=b cwd="$P"; }
b()  { payload tool_name=Bash command="$1" cwd="$P"; }

# ── Write/Edit channel ───────────────────────────────────────────────
assert_deny "$H" "$(wr "$P/.claude/agents/judge.md")"   "R57 Write .claude/agents/judge.md → DENY" "kernel mandate itself"
assert_deny "$H" "$(wr "$P/.claude/agents/evil.md")"    "R57 Write a NEW agent definition → DENY" "kernel mandate itself"
assert_deny "$H" "$(ed "$P/.claude/agents/judge.md")"   "R57 Edit an agent definition → DENY" "kernel mandate itself"
assert_deny "$H" "$(wr "$P/.mcp.json")"                 "R57 Write .mcp.json → DENY" "kernel mandate itself"
assert_deny "$H" "$(wr "$P/.CLAUDE/Agents/judge.md")"   "R57 case-folded spelling → DENY" "kernel mandate itself"
assert_deny "$H" "$(wr "$P/tests/e2e/.claude/agents/x.md")" "R57 nested .claude/agents/ at depth → DENY" "kernel mandate itself"
assert_deny "$H" "$(wr "$P/tests/e2e/.mcp.json")"       "R57 nested .mcp.json at depth → DENY" "kernel mandate itself"

# ── Bash channel ─────────────────────────────────────────────────────
assert_deny "$H" "$(b 'echo "# pwned" > .claude/agents/judge.md')"        "R57 bash redirect into an agent def → DENY" "kernel mandate itself"
assert_deny "$H" "$(b 'cp /tmp/x.md .claude/agents/judge.md')"            "R57 bash cp over an agent def → DENY" "kernel mandate itself"
assert_deny "$H" "$(b 'rm -rf .claude/agents')"                           "R57 bash rm of the agents dir → DENY" "kernel mandate itself"
assert_deny "$H" "$(b 'echo "{}" > .mcp.json')"                           "R57 bash redirect into .mcp.json → DENY" "kernel mandate itself"
assert_deny "$H" "$(b 'sed -i s/a/b/ .mcp.json')"                         "R57 bash sed -i on .mcp.json → DENY" "kernel mandate itself"
assert_deny "$H" "$(b 'tee .mcp.json < /dev/null')"                       "R57 bash tee into .mcp.json → DENY" "kernel mandate itself"

# ── Calibration: reading them is ordinary; lookalikes are not them ───
assert_allow "$H" "$(payload tool_name=Read file_path="$P/.claude/agents/judge.md" cwd="$P")" \
  "R57 calibration: READING an agent definition → ALLOW (it is the role's own law)"
assert_allow "$H" "$(b 'cat .mcp.json')"                "R57 calibration: cat .mcp.json → ALLOW"
assert_allow "$H" "$(wr "$P/src/agents/judge.md")"      "R57 calibration: src/agents/ is not .claude/agents/ → ALLOW"
assert_allow "$H" "$(wr "$P/src/mcp.json")"             "R57 calibration: mcp.json without the dot is not .mcp.json → ALLOW"
assert_allow "$H" "$(wr "$P/docs/my.mcp.json.md")"      "R57 calibration: a longer name containing .mcp.json → ALLOW"
assert_allow "$H" "$(b 'echo x > src/agents.md')"       "R57 calibration: bash write to a lookalike → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R57b"
