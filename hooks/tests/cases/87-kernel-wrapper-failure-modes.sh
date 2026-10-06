#!/bin/bash
# achilles-kernel-activation-gate.sh: a staged manifest with no kernel to run it is refused, not allowed.
H="$HOOK_DIR/achilles-kernel-activation-gate.sh"
KW_TMP=$(mktemp -d); KP="$KW_TMP/proj"; mkdir -p "$KP/.claude" "$KP/src"
cp "$HOOK_DIR/data/achilles-qa.kernel-mandate.json" "$KP/.claude/kernel-mandate.json"
FAKE_HOOKS="$KW_TMP/hooks"; mkdir -p "$FAKE_HOOKS/lib"
cp "$H" "$FAKE_HOOKS/"; cp "$HOOK_DIR/lib/achilles-activation.sh" "$FAKE_HOOKS/lib/"
W="$FAKE_HOOKS/achilles-kernel-activation-gate.sh"
in_scope() { payload tool_name=Read file_path="$KP/package.json" cwd="$KP"; }

section "kernel wrapper: kernel script missing"
export ACHILLES_PROTOCOL=1
assert_deny "$W" "$(in_scope)" "manifest in cwd, kernel file absent → DENY" "kernel-mandate cannot run"
export CLAUDE_PROJECT_DIR="$KP"
assert_deny "$W" "$(payload tool_name=Read file_path=/x cwd="$KW_TMP")" "manifest via CLAUDE_PROJECT_DIR → DENY" "kernel-mandate cannot run"
unset CLAUDE_PROJECT_DIR
for v in 0 false off; do
  KERNEL_MANDATE=$v assert_allow "$W" "$(in_scope)" "operator bypass KERNEL_MANDATE=$v → ALLOW"
done
ACHILLES_PROTOCOL=0 assert_allow "$W" "$(in_scope)" "protocol not active → ALLOW (dormant wrapper)"
rm "$KP/.claude/kernel-mandate.json"
assert_allow "$W" "$(in_scope)" "no manifest, no kernel → ALLOW (nothing to enforce)"
unset ACHILLES_PROTOCOL
rm -rf "$KW_TMP"
