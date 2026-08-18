#!/bin/bash
# Tests for compliance-sweep-exit-gate.sh — Stop / SubagentStop block when a
# session changed test code and never ran the Stage-4b compliance sweep.
H="$HOOK_DIR/compliance-sweep-exit-gate.sh"

TMP_CS=$(mktemp -d /tmp/compliance-sweep-gate-XXXXXX)
trap 'rm -rf "$TMP_CS"' EXIT

# Transcript line builders (claude-code JSONL shape).
tool_line() {  # <tool> <file_path>
  "$JQ" -nc --arg t "$1" --arg f "$2" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:$t, input:{file_path:$f}}]}}'
}
text_line() {
  "$JQ" -nc --arg x "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$x}]}}'
}
stop_payload() {  # <transcript> [hook_event] [stop_hook_active]
  "$JQ" -nc --arg p "$1" --arg e "${2:-Stop}" --argjson a "${3:-false}" \
    '{hook_event_name:$e, transcript_path:$p, stop_hook_active:$a}'
}

WROTE="$TMP_CS/wrote.jsonl"
{ text_line "Writing the login scenario."
  tool_line Write "/repo/tests/e2e/login/login.spec.ts"
  text_line "Test passes 3x."; } > "$WROTE"

SWEPT="$TMP_CS/swept.jsonl"
{ cat "$WROTE"
  text_line "**API Compliance Review**

Reviewed: tests/e2e/login/login.spec.ts — no issues found."; } > "$SWEPT"

SWEPT_BEFORE="$TMP_CS/swept-before.jsonl"
{ text_line "**API Compliance Review** — clean for the previous scenario."
  tool_line Edit "/repo/tests/e2e/login/login.spec.ts"; } > "$SWEPT_BEFORE"

NO_SPEC="$TMP_CS/no-spec.jsonl"
{ tool_line Write "/repo/tests/e2e/fixtures/base.ts"
  tool_line Edit "/repo/README.md"; } > "$NO_SPEC"

# ---------------------------------------------------------------------------
section "compliance-sweep-gate: sessions with no test code are untouched"
assert_allow "$H" "$(stop_payload "$NO_SPEC")" "no spec file written → silent allow"
assert_allow "$H" "$(stop_payload "$TMP_CS/missing.jsonl")" "no transcript on disk → fail open"
assert_allow "$H" "$("$JQ" -nc '{hook_event_name:"Stop"}')" "no transcript_path → fail open"

section "compliance-sweep-gate: the sweep releases the stop"
assert_allow "$H" "$(stop_payload "$SWEPT")" "sweep announced after the write → allow"
assert_allow "$H" "$(stop_payload "$SWEPT" SubagentStop)" "same, on SubagentStop → allow"

section "compliance-sweep-gate: a missing sweep blocks the stop"
assert_block_subagent "$H" "$(stop_payload "$WROTE")" \
  "spec written, no sweep → block" \
  "compliance sweep never ran"
assert_block_subagent "$H" "$(stop_payload "$WROTE" SubagentStop)" \
  "subagent wrote a spec, no sweep → block" \
  "Stage 4b"
assert_block_subagent "$H" "$(stop_payload "$SWEPT_BEFORE")" \
  "sweep predates the last edit → block (a stale sweep proves nothing)" \
  "compliance sweep never ran"
assert_block_subagent "$H" "$(stop_payload "$WROTE")" \
  "block message names the offending file" \
  "tests/e2e/login/login.spec.ts"

section "compliance-sweep-gate: loop safety and kill-switch"
assert_allow "$H" "$(stop_payload "$WROTE" Stop true)" \
  "stop_hook_active → allow (one block per stop chain)"
CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE=1 \
  assert_allow "$H" "$(stop_payload "$WROTE")" \
  "CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE=1 → silent allow"
