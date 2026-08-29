#!/bin/bash
# 04-identity.sh — role-resolution robustness (gap #1: identity).
#
# The dispatch nonce makes a child's binding exact and collision-proof:
# the orchestrator embeds a unique #NONCE in the binding tag, the kernel
# registers nonce→role at dispatch, and the child resolves by the nonce
# in its own transcript. This binds correctly even when the transcript
# also carries a NOISE role tag (quoted context, an unrelated mention)
# that would make the nonce-free "one distinct role" heuristic ambiguous.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate identity / dispatch nonce"

ID=$(mktemp -d)
P="$ID/proj"
mkdir -p "$P/.claude" "$P/src" "$P/docs/acceptance"
printf 'x\n' > "$P/src/app.ts"
printf 'crit\n' > "$P/docs/acceptance/f.md"
export KERNEL_MANDATE_STATE_DIR="$ID/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "id",
  "settings": { "mainSessionRole": "orchestrator", "unboundAgentPolicy": "deny", "ambientDispatchClaim": "on" },
  "roles": {
    "orchestrator": { "description": "dispatch only", "tools": { "allow": ["Agent"] }, "dispatch": ["inspector", "reviewer"] },
    "inspector": { "description": "probe", "tools": { "allow": ["Read"] }, "read": { "allow": ["src/**"] } },
    "reviewer": { "description": "review", "tools": { "allow": ["Read"] }, "read": { "allow": ["docs/acceptance/**"] } }
  }
}
JSON

# --- Dispatch gate accepts a nonced tag ---------------------------------
GOOD_NONCE=$'<<kernel-mandate-role: inspector#n1a2b3>>\nProbe the form.'
assert_allow "$H" "$(payload tool_name=Agent description='inspector-a: probe' prompt="$GOOD_NONCE" tool_use_id=tu-i cwd="$P")" \
  "dispatch with a nonced binding tag → ALLOW"

# The dispatch registered nonce:n1a2b3 → inspector.
TESTS_RUN=$((TESTS_RUN + 1))
if "$JQ" -e '."nonce:n1a2b3".role == "inspector"' "$KERNEL_MANDATE_STATE_DIR/dispatch-registry.json" >/dev/null 2>&1; then
  TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} nonce registered → inspector"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAIL_DETAILS+=("nonce:n1a2b3 not registered")
  echo "${CLR_FAIL}  ✗${CLR_RST} nonce registered → inspector"
fi

# --- Child binds by nonce despite an unregistered NOISE tag -------------
NOISE_TRANSCRIPT="$ID/insp.jsonl"
printf '%s\n' '{"type":"user","content":"<<kernel-mandate-role: inspector#n1a2b3>> probe src. (a mention of <<kernel-mandate-role: reviewer#zzzz99>> that is not a real dispatch)"}' > "$NOISE_TRANSCRIPT"

assert_allow "$H" "$(payload tool_name=Read file_path="$P/src/app.ts" agent_id=child-i transcript_path="$NOISE_TRANSCRIPT" cwd="$P")" \
  "child binds inspector by registered nonce despite an unregistered reviewer noise tag → ALLOW (src in scope)"
assert_deny "$H" "$(payload tool_name=Read file_path="$P/docs/acceptance/f.md" agent_id=child-i transcript_path="$NOISE_TRANSCRIPT" cwd="$P")" \
  "same nonce-bound inspector cannot read reviewer's scope → DENY" "outside the role's read scope"

# --- Nonce-free clean transcript still binds (backward compatible) ------
CLEAN_TRANSCRIPT="$ID/rev.jsonl"
printf '%s\n' '{"type":"user","content":"<<kernel-mandate-role: reviewer>> review the deliverable"}' > "$CLEAN_TRANSCRIPT"
assert_allow "$H" "$(payload tool_name=Read file_path="$P/docs/acceptance/f.md" agent_id=child-c transcript_path="$CLEAN_TRANSCRIPT" cwd="$P")" \
  "nonce-free clean transcript still binds reviewer (rung 4b) → ALLOW"

# --- Dispatch gate still requires SOME tag ------------------------------
assert_deny "$H" "$(payload tool_name=Agent description='inspector-x: probe' prompt='no tag here' tool_use_id=tu-x cwd="$P")" \
  "dispatch missing the binding tag → DENY" "missing the binding tag"

# --- A nonced tag for a DIFFERENT role is still caught as foreign -------
MIXED=$'<<kernel-mandate-role: inspector#aaaa11>>\nand <<kernel-mandate-role: reviewer#bbbb22>> too'
assert_deny "$H" "$(payload tool_name=Agent description='inspector-y: probe' prompt="$MIXED" tool_use_id=tu-y cwd="$P")" \
  "nonced foreign role tag in the prompt → DENY (tag purity, nonce-aware)" "DIFFERENT role"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$ID"
