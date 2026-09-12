#!/bin/bash
# 05-mcp-scoping.sh — MCP argument path-scoping (gap #2).
#
# Core tools name their paths in known fields, so the read/write axes can
# scope them. An MCP tool's argument shape is its own, so the manifest
# declares which arguments of which tools carry paths
# (settings.mcpPathArguments) and the kernel then holds those paths to
# the SAME read/write scopes. Unmapped MCP tools stay name-gated only —
# that boundary is asserted here too, so the honest limit is a tested
# property rather than a claim.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate MCP argument scoping"

MC=$(mktemp -d)
P="$MC/proj"
mkdir -p "$P/.claude" "$P/src" "$P/docs"
printf 'x\n' > "$P/src/app.ts"
printf 'd\n' > "$P/docs/note.md"
printf 'SECRET=1\n' > "$P/.env"
export KERNEL_MANDATE_STATE_DIR="$MC/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "mcp",
  "settings": {
    "mainSessionRole": "writer",
    "mcpPathArguments": {
      "mcp__filesystem__read*": { "read": ["path"] },
      "mcp__filesystem__write*": { "write": ["path"] },
      "mcp__notes__save": { "write": ["target.file"] },
      "mcp__bulk__copy": { "read": ["sources"] }
    }
  },
  "roles": {
    "writer": {
      "description": "Writes docs; may read src and docs.",
      "tools": { "allow": ["mcp__*", "Read"] },
      "read": { "allow": ["src/**", "docs/**"] },
      "write": { "allow": ["docs/**"] }
    }
  }
}
JSON

assert_allow "$H" "$(payload tool_name=mcp__filesystem__write path="$P/docs/note.md" cwd="$P")" \
  "MCP write into the role's write scope → ALLOW"
assert_deny "$H" "$(payload tool_name=mcp__filesystem__write path="$P/src/app.ts" cwd="$P")" \
  "MCP write outside the write scope → DENY" "outside the role's write scope"
assert_deny "$H" "$(payload tool_name=mcp__filesystem__read path="$P/.env" cwd="$P")" \
  "MCP read of an out-of-scope file → DENY" "outside the role's read scope"
assert_allow "$H" "$(payload tool_name=mcp__filesystem__read path="$P/src/app.ts" cwd="$P")" \
  "MCP read inside the read scope → ALLOW"
assert_allow "$H" "$(payload tool_name=mcp__filesystem__read path='https://example.com/x' cwd="$P")" \
  "MCP argument that is a URL is not treated as a path → ALLOW"

# Nested dot-path field.
NESTED=$("$JQ" -nc --arg f "$P/.env" '{tool_name:"mcp__notes__save",tool_input:{target:{file:$f}},cwd:"'"$P"'"}')
assert_deny "$H" "$NESTED" \
  "MCP nested field (target.file) out of write scope → DENY" "outside the role's write scope"

# Array-valued field: every element is checked.
ARR_BAD=$("$JQ" -nc --arg a "$P/src/app.ts" --arg b "$P/.env" '{tool_name:"mcp__bulk__copy",tool_input:{sources:[$a,$b]},cwd:"'"$P"'"}')
assert_deny "$H" "$ARR_BAD" \
  "MCP array field with one out-of-scope element → DENY" "outside the role's read scope"
ARR_OK=$("$JQ" -nc --arg a "$P/src/app.ts" --arg b "$P/docs/note.md" '{tool_name:"mcp__bulk__copy",tool_input:{sources:[$a,$b]},cwd:"'"$P"'"}')
assert_allow "$H" "$ARR_OK" \
  "MCP array field with every element in scope → ALLOW"

# Documented limit: an MCP tool with no mapping entry is name-gated only.
assert_allow "$H" "$(payload tool_name=mcp__unmapped__thing path="$P/.env" cwd="$P")" \
  "unmapped MCP tool is gated by NAME only (documented limit) → ALLOW"
# ...and the name gate still bites.
assert_deny "$H" "$(payload tool_name=Bash command='ls' cwd="$P")" \
  "tool outside the role's allowlist → DENY (name gate intact)" "may not use the 'Bash' tool"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$MC"
