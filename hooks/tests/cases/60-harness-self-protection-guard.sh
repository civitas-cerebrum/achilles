#!/bin/bash
# Tests for harness-self-protection-guard.sh — denies Write|Edit to the
# installed harness surface (~/.claude/hooks/*, settings.json/.local.json).
# PreToolUse:Write|Edit. DENY mode.
H="$HOOK_DIR/harness-self-protection-guard.sh"

we_payload() { "$JQ" -n --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, content:"x"}}'; }

section "harness-self-protection-guard: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls ~/.claude/hooks')" "Bash → silent allow (Bash vector is the other guard's job)"
assert_allow "$H" "$(payload tool_name=Read file_path="$HOME/.claude/settings.json")" "Read → silent allow"

section "harness-self-protection-guard: installed hook surface DENIED"
assert_deny "$H" "$(we_payload Edit "$HOME/.claude/hooks/commit-message-gate.sh")" "Edit ~/.claude/hooks/<x>.sh → DENY" "installed harness"
assert_deny "$H" "$(we_payload Write "$HOME/.claude/hooks/lib/schema-role-map.sh")" "Write ~/.claude/hooks/lib/<x> → DENY" "installed harness"
assert_deny "$H" "$(we_payload Write "$HOME/.claude/settings.json")" "Write settings.json → DENY" "installed harness"
assert_deny "$H" "$(we_payload Edit "$HOME/.claude/settings.local.json")" "Edit settings.local.json → DENY" "installed harness"
# Bare relative form normalises to the same suffix and is still denied.
assert_deny "$H" "$(we_payload Write ".claude/hooks/x.sh")" "relative .claude/hooks/x.sh → DENY" "installed harness"

section "harness-self-protection-guard: spellings that reach the same file DENIED"
for p in "$HOME/.CLAUDE/hooks/a.sh" "$HOME/.claude//hooks/a.sh" "$HOME/.claude/./settings.json" \
         "$HOME/.claude/x/../hooks/a.sh" '~/.claude/settings.json' "$HOME/.claude/Settings.Local.JSON" \
         "$HOME/.claude/achilles/../achilles/sessions/s.active"; do
  assert_deny "$H" "$(we_payload Write "$p")" "Write $p → DENY" "installed harness"
done
for p in "$HOME/.claude/hooks/../skills/a.md" "$HOME/.claude/hooksx/a.sh" "$HOME/.claude/settings.json.bak"; do
  assert_allow "$H" "$(we_payload Write "$p")" "Write near-miss $p → ALLOW"
done

section "harness-self-protection-guard: project-local skills + unrelated paths ALLOWED"
assert_allow "$H" "$(we_payload Write "$HOME/project/.claude/skills/journey-mapping/SKILL.md")" "project-local .claude/skills write → ALLOW"
assert_allow "$H" "$(we_payload Write "/tmp/scratch.txt")" "unrelated path → ALLOW"
assert_allow "$H" "$(we_payload Write "/repo/tests/e2e/spec.ts")" "spec write → ALLOW"

section "harness-self-protection-guard: jq missing (fatal; fail closed while active)"
run_hook_nojq "$H" "$(we_payload Write "/tmp/x")"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "no jq anywhere, active → exit 2, no stdout"
ACHILLES_PROTOCOL=0 run_hook_nojq "$H" "$(we_payload Write "/tmp/x")"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "1:" "no jq anywhere, inactive → exit 1, no stdout"
