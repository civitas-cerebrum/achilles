#!/bin/bash
# 35-reviewer-round29.sh — regressions for round 29 of independent
# adversarial review.
#
# Round 29 found NO demonstrated escape against the benchmark's real
# roles — the first round that could not — and its value is entirely in
# what it found instead: three defects in the identity machinery, each
# latent behind a precondition the bench does not meet, and each the
# same shape as the bugs this project is proudest of closing. Two are
# fixed here. The third is recorded in docs/benchmark.md unfixed,
# because fixing it would break a documented flow on a host assumption
# the kernel cannot verify either way.
#
#   A  THE DISPATCH GATE FAILED OPEN ON AN ABSENT LIST. The entire gate
#      sat inside `if [ "$DISPATCH_LIST" != "null" ]`, so a role that
#      declared no `dispatch` skipped every check — target-in-list,
#      tag-required, tag-purity — while the registration at the bottom
#      still ran and the child still bound. A role holding Agent and
#      nothing else minted a judge with an arbitrary description and no
#      tag at all, and that judge wrote the ledger.
#
#      Absence of a dispatch list is not "dispatch anyone unchecked". It
#      is "this role was never given the authority". Read scope is
#      opt-out because reading is an agent's default posture; handing
#      another agent a ROLE is not.
#
#   C  RUNG 5 RESOLVED IDENTITY FROM AMBIENT STATE. Every other rung
#      answers "this agent is role X" from something tied to the caller:
#      a binding recorded for this agent_id, a parent tool_use_id naming
#      this agent's own dispatch, a tag on this agent's own transcript.
#      Rung 5 answered "some single role is in flight, therefore you are
#      it" — never checking the caller is that dispatch's child — and
#      persisted the binding. With a judge legitimately in flight, an
#      unrelated fresh agent claimed it and wrote the ledger. That is
#      the one direction this project had not found before: a rung
#      resolving a role MORE privileged than the caller holds.
#
#      It was safe only by an emergent property nobody wrote down as
#      load-bearing — registration runs in the parent's PreToolUse,
#      before the child is spawned, so a real child always has its own
#      entry by the time it calls. It is opt-in now
#      (`settings.ambientDispatchClaim: "on"`). Turning it off degrades
#      rather than breaks: an agent that would have been guessed at is
#      unbound, and unboundAgentPolicy — which exists for exactly that
#      caller — decides.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-29 regressions"

R29=$(mktemp -d)
P="$R29/proj"
mkdir -p "$P/.claude" "$P/docs" "$P/tests"
export KERNEL_MANDATE_STATE_DIR="$R29/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

write_manifest() {  # write_manifest <ambientDispatchClaim>
  cat > "$P/.claude/kernel-mandate.json" <<JSON
{
  "kernelMandateVersion": 1,
  "name": "r29",
  "settings": { "mainSessionRole": "orchestrator", "unboundAgentPolicy": "deny", "ambientDispatchClaim": "$1" },
  "roles": {
    "orchestrator": {
      "description": "May summon the workers, deliberately not the judge.",
      "tools": { "allow": ["Agent"] },
      "dispatch": ["composer"]
    },
    "runner": {
      "description": "Holds Agent and declares no dispatch list at all.",
      "tools": { "allow": ["Agent", "Read"] },
      "read": { "allow": ["tests/**"] }
    },
    "composer": {
      "description": "Writes specs.",
      "tools": { "allow": ["Write"] },
      "write": { "allow": ["tests/**"] }
    },
    "judge": {
      "description": "Alone updates the ledger.",
      "tools": { "allow": ["Write", "Read"] },
      "read": { "allow": ["docs/**"] },
      "write": { "allow": ["docs/e2e-ledger.json"] }
    }
  }
}
JSON
}
reset_state() { rm -rf "$KERNEL_MANDATE_STATE_DIR"; mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
  printf 'orchestrator\n' > "$KERNEL_MANDATE_STATE_DIR/agents/orch"
  printf 'runner\n'       > "$KERNEL_MANDATE_STATE_DIR/agents/run1"; }

ap() { "$JQ" -nc --arg a "$1" --arg u "$2" --arg d "$3" --arg pr "$4" \
  '{tool_name:"Agent",tool_input:{description:$d,prompt:$pr},cwd:"'"$P"'",agent_id:$a,tool_use_id:$u}'; }
wp() { "$JQ" -nc --arg a "$1" --arg p "$2" \
  '{tool_name:"Write",tool_input:{file_path:"'"$P"'/docs/e2e-ledger.json",content:"{}"},cwd:"'"$P"'",agent_id:$a}
   | if $p != "" then .parent_tool_use_id = $p else . end'; }

# --- A: an absent dispatch list is a refusal --------------------------
write_manifest off; reset_state
assert_deny "$H" "$(ap run1 tuidA 'judge-x: whatever' 'no tag here at all')" \
  "A a role with no dispatch list may not dispatch → DENY" "declares no 'dispatch' list"
assert_deny "$H" "$(ap run1 tuidA2 'composer-x: write' '<<kernel-mandate-role: composer>>
write it')" \
  "A not even with a correct tag and a role it might plausibly summon → DENY" "declares no 'dispatch' list"
# The registration at the bottom of the gate must not have run either —
# if it did, a child could still bind the minted role.
assert_deny "$H" "$(wp childA tuidA)" \
  "A and no child bound, because nothing was registered → DENY" "could not be resolved"

# The dispatcher that DOES declare a list still works, and its list is
# still a boundary.
assert_allow "$H" "$(ap orch tuidB 'composer-x: write the spec' '<<kernel-mandate-role: composer>>
write it')" \
  "A calibration: a declared dispatch still works → ALLOW"
assert_deny "$H" "$(ap orch tuidC 'judge-x: grade it' '<<kernel-mandate-role: judge>>
grade it')" \
  "A calibration: a role OUTSIDE the list is still refused → DENY" "may not dispatch"

# --- C: the ambient claim is opt-in -----------------------------------
# Stage a judge legitimately in flight, then have an unrelated fresh
# agent — no binding, no parent, no transcript — try to be it.
write_manifest off; reset_state
printf 'orchestrator\n' > "$KERNEL_MANDATE_STATE_DIR/agents/orch2"
"$JQ" -nc '{"tuidJ":{"role":"judge","ts":9999999999}}' > "$KERNEL_MANDATE_STATE_DIR/dispatch-registry.json"
assert_deny "$H" "$(wp attackerX '')" \
  "C an unrelated fresh agent may not claim the judge in flight → DENY" "could not be resolved"
# The real child, which has its own parent tool_use_id, is unaffected —
# that rung is tied to the caller.
assert_allow "$H" "$(wp realchild tuidJ)" \
  "C calibration: the actual child still binds through its parent → ALLOW"

# With the setting ON the old behaviour is available, because on a host
# that supplies neither parent ids nor per-child tags it is the only
# signal there is.
write_manifest on; reset_state
"$JQ" -nc '{"tuidJ":{"role":"judge","ts":9999999999}}' > "$KERNEL_MANDATE_STATE_DIR/dispatch-registry.json"
assert_allow "$H" "$(wp claimant '')" \
  "C the claim is available to a manifest that asks for it → ALLOW"
