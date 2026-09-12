#!/bin/bash
# 59-internal-error-is-a-deny.sh — a kernel bug is a DENY, not a plea.
#
# The exit trap turned any internal error into a non-zero exit with an
# explanation on stderr, and the comment above it said that made the
# gate fail closed. Two independent reviewers ran it against the real
# binary: Claude Code blocks on hook exit 2 only. Exit 1 — what `set -u`
# produces — is a non-blocking error: logged, shown to the model, and
# then the tool runs. One reviewer injected a single unbound variable on
# the Bash path and watched a governed role read a canary secret from
# outside its scope, the refusal printed right above it.
#
# The property "an internal error fails closed" was asserted by
# scripts/test-cli.mjs as `status !== 0` — green while the property was
# false, because the harness could not express it. These cases can: the
# trap must emit the deny JSON on stdout with exit 0, the one channel
# every other deny in this suite is honoured on. And it must do so
# without jq, because the thing that failed may have been jq.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "internal error is a deny (round 56)"

R56=$(mktemp -d)
PROJ56="$R56/proj"
mkdir -p "$PROJ56/.claude" "$PROJ56/docs" "$PROJ56/notes"
echo 'CANARY=zebra-9911' > "$PROJ56/notes/canary.txt"
echo 'x' > "$PROJ56/docs/a.md"
cat > "$PROJ56/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "round56",
  "settings": { "mainSessionRole": "worker" },
  "commandGroups": { "g": ["^(cat|ls)\\b"] },
  "roles": {
    "worker": {
      "description": "Reads docs, runs cat/ls.",
      "tools": { "allow": ["Bash", "Read"] },
      "read": { "allow": ["docs/**"] },
      "bash": { "groups": ["g"] }
    }
  }
}
JSON
export KERNEL_MANDATE_STATE_DIR="$R56/state"
export KERNEL_MANDATE_MANIFEST="$PROJ56/.claude/kernel-mandate.json"

# <marker-line-regex> <name> — a copy of the kernel with one unbound
# variable inserted after the first line matching the regex.
# Copies live in a directory with the kernel's lib/ and bin/ beside them,
# because the hook resolves both relative to its own location.
mkdir -p "$R56/hooks"
cp -r "$HOOK_DIR/lib" "$R56/hooks/lib"
[ -d "$HOOK_DIR/bin" ] && cp -r "$HOOK_DIR/bin" "$R56/hooks/bin"
broken() {
  local re="$1" out="$R56/hooks/$2.sh" n
  cp "$H" "$out"
  n=$(grep -nE "$re" "$out" | head -1 | cut -d: -f1)
  [ -n "$n" ] || { echo "broken(): no line matches $re" >&2; return 1; }
  sed -i "$((n+1))i : \"\$KM_ROUND56_UNBOUND\"" "$out"
  printf '%s' "$out"
}
p() { payload tool_name="${2:-Bash}" command="$1" cwd="$PROJ56"; }

# ── The reviewer's reproduction: a fault AFTER role resolution ────────
B1=$(broken '^kernel_mandate_resolve_role$' after-resolve)
assert_deny "$B1" "$(p 'cat notes/canary.txt')" \
  "R56 unbound variable after role resolution → DENY, not exit 1" "internal error"
# The fault must not be mistaken for a scope verdict: the reason names
# the kernel, and stderr still tells the operator what broke.
assert_deny "$B1" "$(p 'cat docs/a.md')" \
  "R56 ...even for a call the role WOULD have been allowed" "bug in the kernel"

# ── A fault before the manifest is even loaded ───────────────────────
# The hook cannot know whether it is governed if it crashed before
# finding out. Fail closed.
B2=$(broken '^INPUT=\$\(cat\)$' after-input)
assert_deny "$B2" "$(p 'ls')" \
  "R56 unbound variable right after reading stdin → DENY" "internal error"

# ── The verdict must be on STDOUT with EXIT 0 — the honoured channel ──
out=$(p 'cat notes/canary.txt' | bash "$B1" 2>/dev/null); rc=$?
assert_eq "$rc" "0" "R56 the trap exits 0, not the fault's status"
assert_eq "$(printf '%s' "$out" | "$JQ" -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" "deny" \
  "R56 ...and stdout is parseable deny JSON"
err=$(p 'cat notes/canary.txt' | bash "$B1" 2>&1 >/dev/null)
case "$err" in *"INTERNAL ERROR"*) assert_eq 1 1 "R56 stderr still says INTERNAL ERROR for the operator" ;;
  *) assert_eq "$err" "…INTERNAL ERROR…" "R56 stderr still says INTERNAL ERROR for the operator" ;; esac

# ── No jq dependency in the trap: break jq, verdict still renders ────
B3="$R56/hooks/nojq.sh"; cp "$B1" "$B3"
# Route the bundled jq lookup to a broken binary AFTER the manifest has
# been parsed, by clobbering KM_JQ on the same line as the fault.
sed -i 's|: "\$KM_ROUND56_UNBOUND"|KM_JQ=/nonexistent/jq; JQ=/nonexistent/jq; : "$KM_ROUND56_UNBOUND"|' "$B3"
out=$(p 'cat notes/canary.txt' | bash "$B3" 2>/dev/null); rc=$?
assert_eq "$rc" "0" "R56 with jq unreachable at fault time, still exit 0"
case "$out" in *'"permissionDecision":"deny"'*) assert_eq 1 1 "R56 ...and the deny JSON is still rendered (printf, not jq)" ;;
  *) assert_eq "$out" "…permissionDecision:deny…" "R56 ...and the deny JSON is still rendered (printf, not jq)" ;; esac

# ── Calibration: the trap stays out of the way of real verdicts ──────
assert_allow "$H" "$(p 'cat docs/a.md')" \
  "R56 calibration: an ordinary allow is still silent, exit 0"
assert_deny "$H" "$(p 'cat notes/canary.txt')" \
  "R56 calibration: an ordinary scope deny is unchanged" "read scope"
# A fault INSIDE the deny path — after the decision, before the JSON is
# written — is the narrowest window and the one that was open: KM_DECIDED
# used to be raised before emission, so the trap stood down on a verdict
# that never reached stdout. The kernel copy here is unbroken; the fault
# goes into ITS lib copy, inside kernel_mandate_deny, before the printf.
B4="$R56/hooks/inside-deny.sh"; cp "$H" "$B4"
mkdir -p "$R56/hooks-deny"; cp "$B4" "$R56/hooks-deny/inside-deny.sh"; cp -r "$R56/hooks/lib" "$R56/hooks-deny/lib"
[ -d "$R56/hooks/bin" ] && cp -r "$R56/hooks/bin" "$R56/hooks-deny/bin"
n=$(grep -nE '^kernel_mandate_deny\(\) \{$' "$R56/hooks-deny/lib/kernel-mandate.sh" | head -1 | cut -d: -f1)
sed -i "$((n+2))i : \"\$KM_ROUND56_UNBOUND\"" "$R56/hooks-deny/lib/kernel-mandate.sh"
out=$(p 'cat notes/canary.txt' | bash "$R56/hooks-deny/inside-deny.sh" 2>/dev/null); rc=$?
assert_eq "$rc" "0" "R56 a fault inside the deny path still exits 0"
assert_eq "$(printf '%s' "$out" | grep -c permissionDecision)" "1" \
  "R56 ...with exactly one verdict on stdout"
assert_eq "$(printf '%s' "$out" | "$JQ" -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" "deny" \
  "R56 ...and it is a deny"

# The operator's kill switch still outranks a broken kernel.
KERNEL_MANDATE=0 assert_allow "$B1" "$(p 'cat notes/canary.txt')" \
  "R56 KERNEL_MANDATE=0 outranks the internal error → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R56"
