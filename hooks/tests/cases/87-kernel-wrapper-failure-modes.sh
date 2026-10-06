#!/bin/bash
# achilles-kernel-activation-gate.sh: a staged manifest with no kernel to run it is refused, not allowed.
H="$HOOK_DIR/achilles-kernel-activation-gate.sh"
KW_TMP=$(mktemp -d); KP="$KW_TMP/proj"; mkdir -p "$KP/.claude" "$KP/src"
cp "$HOOK_DIR/data/achilles-qa.kernel-mandate.json" "$KP/.claude/kernel-mandate.json"
FAKE_HOOKS="$KW_TMP/hooks"; mkdir -p "$FAKE_HOOKS/lib"
cp "$H" "$FAKE_HOOKS/"; cp "$HOOK_DIR/lib/achilles-activation.sh" "$HOOK_DIR/lib/dispatch-prefix.sh" "$FAKE_HOOKS/lib/"
W="$FAKE_HOOKS/achilles-kernel-activation-gate.sh"
in_scope() { payload tool_name=Read file_path="$KP/package.json" cwd="$KP"; }

unset CLAUDE_PROJECT_DIR KERNEL_MANDATE KERNEL_MANDATE_MANIFEST

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

section "kernel wrapper: kernel present but unrunnable"
KF="$FAKE_HOOKS/kernel-mandate-role-gate.sh"
: > "$KF"
assert_deny "$W" "$(in_scope)" "empty kernel file → DENY" "kernel-mandate cannot run"
rm "$KF"; mkdir "$KF"
assert_deny "$W" "$(in_scope)" "kernel path is a directory → DENY" "kernel-mandate cannot run"
rmdir "$KF"; printf '#!/bin/bash\nexit 7\n' > "$KF"
assert_deny "$W" "$(in_scope)" "kernel exits 7 → DENY" "kernel exited 7"
printf '#!/bin/bash\ncat >/dev/null; exit 2\n' > "$KF"
assert_eq "$(printf '%s' "$(in_scope)" | bash "$W" >/dev/null 2>&1; echo $?)" "2" "kernel exit 2 is relayed"
KERNEL_MANDATE=off assert_allow "$W" "$(in_scope)" "kernel exits 2 under bypass → ALLOW"
printf '#!/bin/bash\nexit 7\n' > "$KF"
KERNEL_MANDATE=off assert_allow "$W" "$(in_scope)" "bypass wins over a broken kernel → ALLOW"
rm "$KF"

section "kernel wrapper: project root found through git"
git -C "$KP" init -q; mkdir -p "$KP/src/deep"
assert_deny "$W" "$(payload tool_name=Read file_path=/x cwd="$KP/src/deep")" "cwd in a subdir, manifest at git root → DENY" "kernel-mandate cannot run"
rm -rf "$KP/.git"

rm "$KP/.claude/kernel-mandate.json"
assert_allow "$W" "$(in_scope)" "no manifest, no kernel → ALLOW (nothing to enforce)"
unset ACHILLES_PROTOCOL
rm -rf "$KW_TMP"
