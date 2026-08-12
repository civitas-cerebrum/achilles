#!/bin/bash
# Tests for failure-diagnosis-evidence-floor-gate.sh — denies spec /
# element-repository writes from a failure-diagnosis context whose transcript
# shows no failure-evidence access at all.
#
# Allow-test convention (lib.sh): every deny here ships with adjacent-traffic
# allows — the same write from a NON-diagnosis session (composer authoring a
# spec), the same write after any single evidence read, and non-gated paths.
H="$HOOK_DIR/failure-diagnosis-evidence-floor-gate.sh"

TMP_DIR=$(mktemp -d /tmp/fd-evidence-floor-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- transcripts ------------------------------------------------------------

# fd context (Skill invocation) + NO evidence reads. The violation shape:
# the whole diagnosis came out of `gh run view --log-failed`.
FD_NO_EVIDENCE="$TMP_DIR/fd-no-evidence.jsonl"
cat > "$FD_NO_EVIDENCE" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"the nightly failed"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"failure-diagnosis"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh run view 123 --job 456 --log-failed"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/apps/e2e/docs/app-context.md"}}]}}
EOF

# fd context via a plugin-prefixed Skill name.
FD_PREFIXED_SKILL="$TMP_DIR/fd-prefixed.jsonl"
cat > "$FD_PREFIXED_SKILL" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"achilles:failure-diagnosis"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npx playwright test --grep checkout-guest"}}]}}
EOF

# fd context via a Read of the skill file (bundled package path).
FD_SKILL_READ="$TMP_DIR/fd-skill-read.jsonl"
cat > "$FD_SKILL_READ" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/node_modules/@civitas-cerebrum/achilles/skills/failure-diagnosis/SKILL.md"}}]}}
EOF

# fd context via an fd-ci-* role dispatch (orchestrator side).
FD_ROLE_DISPATCH="$TMP_DIR/fd-role.jsonl"
cat > "$FD_ROLE_DISPATCH" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"description":"fd-ci-18234771:","prompt":"diagnose run 18234771"}}]}}
EOF

# fd context via a repair-worker-* role dispatch (self-repair worker).
REPAIR_WORKER="$TMP_DIR/repair-worker.jsonl"
cat > "$REPAIR_WORKER" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"description":"repair-worker-checkout:","prompt":"repair tests/e2e/checkout.spec.ts"}}]}}
EOF

# NO fd context at all — a composer authoring a spec. Must never be gated.
COMPOSER="$TMP_DIR/composer.jsonl"
cat > "$COMPOSER" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"test-composer"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"description":"composer-j-login:","prompt":"compose the login journey"}}]}}
EOF

# Helper: fd transcript + one evidence signal appended.
fd_with_evidence() {
  local name=$1 line=$2
  local path="$TMP_DIR/fd-evidence-$name.jsonl"
  cp "$FD_NO_EVIDENCE" "$path"
  printf '%s\n' "$line" >> "$path"
  printf '%s' "$path"
}

TRACE_UNZIP=$(fd_with_evidence trace-unzip \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"unzip -o -q /tmp/ci/test-results/x-retry1/trace.zip -d ./trace-x"}}]}}')
SHOW_TRACE=$(fd_with_evidence show-trace \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npx playwright show-trace ./trace.zip"}}]}}')
ERROR_CONTEXT=$(fd_with_evidence error-context \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/ci/test-results/checkout-guest-mobile-chrome/error-context.md"}}]}}')
SCREENSHOT=$(fd_with_evidence screenshot \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/ci/test-results/checkout-guest-mobile-chrome/test-failed-1.png"}}]}}')
VIDEO=$(fd_with_evidence video \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/ci/test-results/checkout-guest-mobile-chrome/video.webm"}}]}}')
GH_DOWNLOAD=$(fd_with_evidence gh-download \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh run download 18234771 --dir /tmp/ci"}}]}}')
REPORTER_JSON=$(fd_with_evidence reporter-json \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"jq -r .stats /tmp/ci/test-results/mobile-results.json"}}]}}')

# --- payload helpers --------------------------------------------------------

SPEC_PATH="$TMP_DIR/apps/e2e/checkout.spec.ts"
REPO_PATH="$TMP_DIR/apps/e2e/elements/page-repository.json"
mkdir -p "$(dirname "$SPEC_PATH")" "$(dirname "$REPO_PATH")"

write_payload() {
  local path=$1 transcript=$2 tool=${3:-Write}
  "$JQ" -n --arg fp "$path" --arg tp "$transcript" --arg tn "$tool" '{
    tool_name: $tn,
    tool_input: { file_path: $fp, content: "await steps.waitForState(...)" },
    transcript_path: $tp
  }'
}

# ---------------------------------------------------------------------------
section "fd-evidence-floor: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright test' transcript_path="$FD_NO_EVIDENCE")" \
  "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Read file_path="$SPEC_PATH" transcript_path="$FD_NO_EVIDENCE")" \
  "Read of the spec → silent allow (reading is not writing)"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: non-gated paths silent-allow"
assert_allow "$H" "$(write_payload "$TMP_DIR/apps/e2e/docs/app-context.md" "$FD_NO_EVIDENCE")" \
  "Write app-context.md (knowledge write-back) → silent allow"
assert_allow "$H" "$(write_payload "$TMP_DIR/apps/e2e/docs/flake-quarantine.md" "$FD_NO_EVIDENCE")" \
  "Write flake-quarantine.md (ledger) → silent allow"
assert_allow "$H" "$(write_payload "$TMP_DIR/playwright.config.ts" "$FD_NO_EVIDENCE")" \
  "Write playwright.config.ts → silent allow"
assert_allow "$H" "$(write_payload "$TMP_DIR/apps/e2e/fixtures/StepFixture.ts" "$FD_NO_EVIDENCE")" \
  "Write a non-spec .ts → silent allow"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: NO fd context → never gated (adjacent traffic)"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$COMPOSER")" \
  "composer session writes a spec, no evidence reads → silent allow"
assert_allow "$H" "$(write_payload "$REPO_PATH" "$COMPOSER")" \
  "composer session writes page-repository.json → silent allow"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: fd context + ZERO evidence → DENY"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$FD_NO_EVIDENCE")" \
  "Skill(failure-diagnosis), log-only, Write spec → DENY" "Evidence-floor violation"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$FD_NO_EVIDENCE" Edit)" \
  "Skill(failure-diagnosis), log-only, Edit spec → DENY" "Evidence-floor violation"
assert_deny "$H" "$(write_payload "$REPO_PATH" "$FD_NO_EVIDENCE")" \
  "Skill(failure-diagnosis), log-only, Write page-repository.json → DENY" "element repository"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$FD_PREFIXED_SKILL")" \
  "plugin-prefixed Skill(achilles:failure-diagnosis) → DENY" "Evidence-floor violation"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$FD_SKILL_READ")" \
  "fd context via Read of failure-diagnosis/SKILL.md → DENY" "Evidence-floor violation"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$FD_ROLE_DISPATCH")" \
  "fd context via fd-ci-* dispatch → DENY" "Evidence-floor violation"
assert_deny "$H" "$(write_payload "$SPEC_PATH" "$REPAIR_WORKER")" \
  "fd context via repair-worker-* dispatch → DENY" "Evidence-floor violation"

# Deny message must carry the actionable remediation, not just the diagnosis.
run_hook "$H" "$(write_payload "$SPEC_PATH" "$FD_NO_EVIDENCE")"
DENY_REASON=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // empty')
assert_eq "$(echo "$DENY_REASON" | grep -q 'gh run download' && echo found || echo missing)" "found" \
  "deny message names the pipeline remediation (gh run download)"
assert_eq "$(echo "$DENY_REASON" | grep -q 'retry1' && echo found || echo missing)" "found" \
  "deny message warns about the attempt/retry split"
assert_eq "$(echo "$DENY_REASON" | grep -q 'FD_EVIDENCE_FLOOR_GATE=off' && echo found || echo missing)" "found" \
  "deny message names its own escape hatch"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: fd context + ANY evidence signal → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$TRACE_UNZIP")" \
  "unzip trace.zip → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$SHOW_TRACE")" \
  "playwright show-trace → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$ERROR_CONTEXT")" \
  "Read error-context.md → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$SCREENSHOT")" \
  "Read test-failed-1.png → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$VIDEO")" \
  "Read video.webm → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$GH_DOWNLOAD")" \
  "gh run download → ALLOW"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$REPORTER_JSON")" \
  "jq over <shard>-results.json → ALLOW"
assert_allow "$H" "$(write_payload "$REPO_PATH" "$ERROR_CONTEXT")" \
  "page-repository.json write after an evidence read → ALLOW"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: fail-open cases"
NO_TRANSCRIPT=$(write_payload "$SPEC_PATH" "" | "$JQ" 'del(.transcript_path)')
assert_allow "$H" "$NO_TRANSCRIPT" \
  "missing transcript_path → silent allow (fail open)"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "/tmp/does-not-exist-fd-xyz.jsonl")" \
  "nonexistent transcript_path → silent allow (fail open)"
EMPTY_TRANSCRIPT="$TMP_DIR/empty.jsonl"
: > "$EMPTY_TRANSCRIPT"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$EMPTY_TRANSCRIPT")" \
  "empty transcript → silent allow (no fd context to gate)"
assert_allow "$H" "$(write_payload "$SPEC_PATH" "$FD_NO_EVIDENCE" | "$JQ" 'del(.tool_input.file_path)')" \
  "missing file_path → silent allow"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: bare relative spec path is gated like absolute"
REL_WRITE=$("$JQ" -n --arg tp "$FD_NO_EVIDENCE" '{
  tool_name: "Edit",
  tool_input: { file_path: "apps/e2e/checkout.spec.ts", old_string: "a", new_string: "b" },
  transcript_path: $tp
}')
assert_deny "$H" "$REL_WRITE" \
  "relative spec path, fd context, no evidence → DENY" "Evidence-floor violation"

# ---------------------------------------------------------------------------
section "fd-evidence-floor: FD_EVIDENCE_FLOOR_GATE=off bypass"
BYPASS_OUT="$TMP_DIR/bypass.out"
FD_EVIDENCE_FLOOR_GATE=off bash -c "printf '%s' '$(write_payload "$SPEC_PATH" "$FD_NO_EVIDENCE" | tr -d '\n')' | bash '$H'" > "$BYPASS_OUT" 2>&1
if grep -q "permissionDecision" "$BYPASS_OUT"; then
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  FAIL_DETAILS+=("BYPASS test: expected silent allow under FD_EVIDENCE_FLOOR_GATE=off, got deny")
  echo "${CLR_FAIL}  ✗${CLR_RST} FD_EVIDENCE_FLOOR_GATE=off bypass"
else
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} FD_EVIDENCE_FLOOR_GATE=off bypass"
fi
