#!/bin/bash
# Tests for perf-onboarding-ledger-write-gate.sh — schema + state-machine
# integrity gate for writes to tests/perf/docs/perf-onboarding-status.json.
# PreToolUse:Write|Edit. DENY mode.
H="$HOOK_DIR/perf-onboarding-ledger-write-gate.sh"

# Skip if node / ajv is unavailable (same pattern as onboarding write-gate tests).
if ! command -v node >/dev/null 2>&1; then
  echo "  ${CLR_DIM}(node not on PATH — skipping perf-onboarding-ledger-write-gate cases)${CLR_RST}"
  return 0 2>/dev/null || exit 0
fi
NODE_BIN=$(command -v node)
if ! "$NODE_BIN" -e "require('ajv/dist/2020.js'); require('ajv-formats');" >/dev/null 2>&1; then
  echo "  ${CLR_DIM}(ajv/ajv-formats not available — skipping perf-onboarding-ledger-write-gate cases)${CLR_RST}"
  return 0 2>/dev/null || exit 0
fi

TMP_REPO=$(mktemp -d /tmp/perf-ledger-write-XXXXXX)
mkdir -p "$TMP_REPO/tests/perf/docs"
(cd "$TMP_REPO" && git init -q && git config user.email t@t && git config user.name t)
trap 'rm -rf "$TMP_REPO"' EXIT

LEDGER_PATH="$TMP_REPO/tests/perf/docs/perf-onboarding-status.json"

# Baseline valid perf ledger (7 phases matching perf-onboarding-status schema).
VALID_FRESH_PERF='{
  "schemaVersion": 1,
  "pipelineVersion": "0.1.0",
  "runMode": "standard",
  "modeAuthorizer": "user chose standard mode for perf run",
  "startedAt": "2026-06-01T09:00:00Z",
  "currentPhase": 1,
  "currentSubStage": null,
  "status": "in-progress",
  "phases": [
    {"id":1,"name":"Scaffold","status":"in-progress","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]},
    {"id":2,"name":"Readiness","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]},
    {"id":3,"name":"Scenario-model","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]},
    {"id":4,"name":"Baseline","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]},
    {"id":5,"name":"Load-run","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[],"subStages":[]},
    {"id":6,"name":"Threshold-gate","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]},
    {"id":7,"name":"Report","status":"pending","reviewerVerdict":"pending","reviewerCycles":0,"deliverables":[]}
  ],
  "approvedDeviations": []
}'

# ---------------------------------------------------------------------------
section "perf-write-gate: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls')" "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Read file_path='/tmp/x')" "Read → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='whatever')" "Agent → silent allow"

# ---------------------------------------------------------------------------
section "perf-write-gate: non-ledger paths silent-allow"
assert_allow "$H" "$(payload tool_name=Write file_path='/tmp/anything.json' content='{}')" \
  "Write to /tmp/anything.json → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_REPO/tests/perf/docs/readiness.md" content='# Readiness')" \
  "Write to readiness.md → silent allow (different file)"
assert_allow "$H" "$(payload tool_name=Write file_path='/repo/tests/e2e/docs/onboarding-status.json' content='{}')" \
  "Write to onboarding-status.json (wrong pipeline) → silent allow"

# ---------------------------------------------------------------------------
section "perf-write-gate: fresh-run init with valid JSON ALLOWED"
rm -f "$LEDGER_PATH"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$VALID_FRESH_PERF")" \
  "Write fresh valid perf ledger → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: malformed JSON DENIED"
rm -f "$LEDGER_PATH"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content='not-json-at-all')" \
  "Write non-JSON content to perf ledger → DENY" "not parseable JSON"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content='{"unterminated":')" \
  "Write truncated JSON to perf ledger → DENY" "not parseable JSON"

# ---------------------------------------------------------------------------
section "perf-write-gate: schema-invalid content DENIED"
rm -f "$LEDGER_PATH"
# Missing required 'phases' field.
INVALID_MISSING_PHASES='{"schemaVersion":1,"pipelineVersion":"0.1.0","runMode":"standard","startedAt":"2026-06-01T09:00:00Z","currentPhase":1,"status":"in-progress"}'
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$INVALID_MISSING_PHASES")" \
  "Write perf ledger missing required 'phases' → DENY" "fails schema validation"

# Bad runMode enum value.
INVALID_BAD_RUNMODE='{"schemaVersion":1,"pipelineVersion":"0.1.0","runMode":"yolo","startedAt":"2026-06-01T09:00:00Z","currentPhase":1,"status":"in-progress","phases":[
  {"id":1,"name":"Scaffold","status":"in-progress","deliverables":[]},
  {"id":2,"name":"Readiness","status":"pending","deliverables":[]},
  {"id":3,"name":"Scenario-model","status":"pending","deliverables":[]},
  {"id":4,"name":"Baseline","status":"pending","deliverables":[]},
  {"id":5,"name":"Load-run","status":"pending","deliverables":[]},
  {"id":6,"name":"Threshold-gate","status":"pending","deliverables":[]},
  {"id":7,"name":"Report","status":"pending","deliverables":[]}
]}'
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$INVALID_BAD_RUNMODE")" \
  "Write perf ledger with bad runMode enum → DENY" "fails schema validation"

# ---------------------------------------------------------------------------
section "perf-write-gate: phase-skip transition DENIED"
printf '%s' "$VALID_FRESH_PERF" > "$LEDGER_PATH"
# Jump from phase 1 → phase 3, skipping phase 2 still pending.
SKIP_TWO=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 3 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "approved" |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"}
')
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$SKIP_TWO")" \
  "Write that jumps phase 1 → 3 with phase 2 pending → DENY" "Out-of-order ledger transition"

# ---------------------------------------------------------------------------
section "perf-write-gate: reviewerVerdict approved without handoverEnvelope DENIED"
printf '%s' "$VALID_FRESH_PERF" > "$LEDGER_PATH"
APPROVED_NO_HANDOVER=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "approved" |
  .phases[0].handoverEnvelope = null
')
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$APPROVED_NO_HANDOVER")" \
  "Write perf approval verdict without handoverEnvelope → DENY" "handoverEnvelope is null"

# ---------------------------------------------------------------------------
section "perf-write-gate: actor-identity on approval transitions"
# The prior ledger already has Phase 1 completed+approved, Phase 2 in-progress.
# The proposed write approves Phase 2, so the deliverable check fires for Phase 2.
# We ensure readiness.md exists before the allow test so the deliverable check passes.
PRIOR_P1_APPROVED=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "approved" |
  .phases[0].reviewerCycles = 1 |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"} |
  .phases[1].status = "in-progress"
')
printf '%s' "$PRIOR_P1_APPROVED" > "$LEDGER_PATH"
IN_ORDER=$(echo "$PRIOR_P1_APPROVED" | "$JQ" '
  .phases[1].status = "completed" |
  .phases[1].reviewerVerdict = "approved" |
  .phases[1].reviewerCycles = 1 |
  .phases[1].handoverEnvelope = {"role":"readiness","status":"complete"}
')

# Orchestrator-direct (no agent_id) → DENY.
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$IN_ORDER")" \
  "Orchestrator direct write approving perf phase → DENY" "separation-of-duties"

# Subagent context + fresh approver registry → ALLOW.
# Phase 2 deliverable: readiness.md must exist.
mkdir -p "$TMP_REPO/tests/perf/docs"
printf '# Readiness\n' > "$TMP_REPO/tests/perf/docs/readiness.md"
NOW=$(date +%s)
REGISTRY="$TMP_REPO/tests/perf/docs/.workflow-approvers.json"
printf '{"toolu_perf_approved":{"role":"perf-reviewer","description":"perf-reviewer-phase2","ts":%d}}' "$NOW" > "$REGISTRY"
P_OK=$(payload tool_name=Write file_path="$LEDGER_PATH" content="$IN_ORDER")
P_OK=$(echo "$P_OK" | "$JQ" -c '. + {agent_id: "perf-subagent-abc", agent_type: "general-purpose"}')
assert_allow "$H" "$P_OK" "Perf subagent context + fresh approver registry → ALLOW"

# Write that doesn't change any reviewerVerdict → ALLOW even from orchestrator.
printf '%s' "$PRIOR_P1_APPROVED" > "$LEDGER_PATH"
rm -f "$REGISTRY"
NO_APPROVAL=$(echo "$PRIOR_P1_APPROVED" | "$JQ" '.phases[1].deliverables = ["tests/perf/docs/readiness.md"]')
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$NO_APPROVAL")" \
  "Orchestrator non-approval write (deliverables update) → ALLOW"

rm -f "$LEDGER_PATH" "$REGISTRY"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 1 → completed requires config + non-empty lib/"
rm -f "$LEDGER_PATH"
PRIOR_P1=$(echo "$VALID_FRESH_PERF" | "$JQ" '.phases[0].status = "in-progress" | .currentPhase = 1')
printf '%s' "$PRIOR_P1" > "$LEDGER_PATH"
COMPLETED_P1=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .phases[0].status = "completed" |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"} |
  .currentPhase = 1
')

assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P1")" \
  "Phase 1 → completed with no config.json → DENY" "perf-onboarding.config.json does not exist"

mkdir -p "$TMP_REPO/tests/perf"
printf '{"targets":{"allowlist":[]}}' > "$TMP_REPO/tests/perf/perf-onboarding.config.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P1")" \
  "Phase 1 → completed with config but empty lib/ → DENY" "tests/perf/lib/"

mkdir -p "$TMP_REPO/tests/perf/lib"
printf '// shared helper\n' > "$TMP_REPO/tests/perf/lib/auth.js"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P1")" \
  "Phase 1 → completed with config + non-empty lib/ → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 2 → completed requires readiness.md"
rm -f "$LEDGER_PATH"
PRIOR_P2=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "in-progress"
')
printf '%s' "$PRIOR_P2" > "$LEDGER_PATH"
COMPLETED_P2=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].handoverEnvelope = {"role":"readiness","status":"complete"}
')

rm -f "$TMP_REPO/tests/perf/docs/readiness.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P2")" \
  "Phase 2 → completed without readiness.md → DENY" "readiness.md does not exist"

printf '# Readiness Assessment\nAll checks passed.\n' > "$TMP_REPO/tests/perf/docs/readiness.md"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P2")" \
  "Phase 2 → completed with readiness.md → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 3 → completed requires scenario-model.md + sentinel + scenarios/*.js"
rm -f "$LEDGER_PATH"
PRIOR_P3=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 3 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "in-progress"
')
printf '%s' "$PRIOR_P3" > "$LEDGER_PATH"
COMPLETED_P3=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 3 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].handoverEnvelope = {"role":"scenario-model","status":"complete"}
')

rm -f "$TMP_REPO/tests/perf/docs/scenario-model.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P3")" \
  "Phase 3 → completed without scenario-model.md → DENY" "scenario-model.md does not exist"

echo "# Scenario Model (no sentinel)" > "$TMP_REPO/tests/perf/docs/scenario-model.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P3")" \
  "Phase 3 → completed with sentinel-less scenario-model.md → DENY" "line-1 sentinel"

printf '<!-- perf-onboarding:scenario-model -->\n# Scenario Model\n' > "$TMP_REPO/tests/perf/docs/scenario-model.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P3")" \
  "Phase 3 → completed with no scenarios/*.js → DENY" "no *.js scenario files"

mkdir -p "$TMP_REPO/tests/perf/scenarios"
printf 'import http from "k6/http";\n' > "$TMP_REPO/tests/perf/scenarios/load.js"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P3")" \
  "Phase 3 → completed with sentinel + ≥1 scenario → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 4 → completed requires ≥1 baselines/*.json"
rm -f "$LEDGER_PATH"
PRIOR_P4=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 4 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "in-progress"
')
printf '%s' "$PRIOR_P4" > "$LEDGER_PATH"
COMPLETED_P4=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 4 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].handoverEnvelope = {"role":"baseline","status":"complete"}
')

assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P4")" \
  "Phase 4 → completed without baselines/*.json → DENY" "no *.json baseline files"

mkdir -p "$TMP_REPO/tests/perf/baselines"
printf '{"p95":120,"p99":250}\n' > "$TMP_REPO/tests/perf/baselines/load-baseline.json"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P4")" \
  "Phase 4 → completed with ≥1 baseline JSON → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 5 → completed requires ≥1 results/*.json"
rm -f "$LEDGER_PATH"
PRIOR_P5=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 5 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress"
')
printf '%s' "$PRIOR_P5" > "$LEDGER_PATH"
COMPLETED_P5=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 5 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "completed" | .phases[4].handoverEnvelope = {"role":"load-run","status":"complete"}
')

assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P5")" \
  "Phase 5 → completed without results/*.json → DENY" "no *.json result files"

mkdir -p "$TMP_REPO/tests/perf/results"
printf '{"metrics":{"http_req_duration":{"p95":98}}}\n' > "$TMP_REPO/tests/perf/results/load-2026-06-01.json"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P5")" \
  "Phase 5 → completed with ≥1 result JSON → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 6 → completed requires threshold-verdict.json + deliberateBreach"
rm -f "$LEDGER_PATH"
PRIOR_P6=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 6 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "completed" | .phases[4].reviewerVerdict = "approved" | .phases[4].handoverEnvelope = {} |
  .phases[5].status = "in-progress"
')
printf '%s' "$PRIOR_P6" > "$LEDGER_PATH"
COMPLETED_P6=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 6 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "completed" | .phases[4].reviewerVerdict = "approved" | .phases[4].handoverEnvelope = {} |
  .phases[5].status = "completed" | .phases[5].handoverEnvelope = {"role":"threshold-gate","status":"complete"}
')

rm -f "$TMP_REPO/tests/perf/docs/threshold-verdict.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P6")" \
  "Phase 6 → completed without threshold-verdict.json → DENY" "threshold-verdict.json does not exist"

# Verdict file missing deliberateBreach → DENY.
printf '{"thresholds":"passed"}\n' > "$TMP_REPO/tests/perf/docs/threshold-verdict.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P6")" \
  "Phase 6 → completed with threshold-verdict.json but no deliberateBreach → DENY" "deliberateBreach"

# deliberateBreach present (empty array, jq -e '.deliberateBreach | length > 0' → false) → DENY.
printf '{"deliberateBreach":[]}\n' > "$TMP_REPO/tests/perf/docs/threshold-verdict.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P6")" \
  "Phase 6 → completed with empty deliberateBreach → DENY" "deliberateBreach"

# deliberateBreach with entry → ALLOW.
printf '{"deliberateBreach":[{"threshold":"p95<200ms","verdict":"pass"}]}\n' > "$TMP_REPO/tests/perf/docs/threshold-verdict.json"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P6")" \
  "Phase 6 → completed with threshold-verdict.json + non-empty deliberateBreach → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: Phase 7 → completed requires perf-report.md + sentinel"
rm -f "$LEDGER_PATH"
PRIOR_P7=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 7 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "completed" | .phases[4].reviewerVerdict = "approved" | .phases[4].handoverEnvelope = {} |
  .phases[5].status = "completed" | .phases[5].reviewerVerdict = "approved" | .phases[5].handoverEnvelope = {} |
  .phases[6].status = "in-progress"
')
printf '%s' "$PRIOR_P7" > "$LEDGER_PATH"
COMPLETED_P7=$(echo "$VALID_FRESH_PERF" | "$JQ" '
  .currentPhase = 7 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "completed" | .phases[4].reviewerVerdict = "approved" | .phases[4].handoverEnvelope = {} |
  .phases[5].status = "completed" | .phases[5].reviewerVerdict = "approved" | .phases[5].handoverEnvelope = {} |
  .phases[6].status = "completed" | .phases[6].handoverEnvelope = {"role":"perf-report","status":"complete"}
')

rm -f "$TMP_REPO/tests/perf/docs/perf-report.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P7")" \
  "Phase 7 → completed without perf-report.md → DENY" "perf-report.md does not exist"

echo "# Perf Report (no sentinel)" > "$TMP_REPO/tests/perf/docs/perf-report.md"
assert_deny "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P7")" \
  "Phase 7 → completed with sentinel-less perf-report.md → DENY" "line-1 sentinel"

printf '<!-- perf-onboarding:report -->\n# Perf Report\n' > "$TMP_REPO/tests/perf/docs/perf-report.md"
assert_allow "$H" "$(payload tool_name=Write file_path="$LEDGER_PATH" content="$COMPLETED_P7")" \
  "Phase 7 → completed with perf-report.md + sentinel → ALLOW"

# ---------------------------------------------------------------------------
section "perf-write-gate: BARE RELATIVE path is gated like an absolute one"
assert_deny "$H" "$(payload tool_name=Write file_path='tests/perf/docs/perf-onboarding-status.json' content='not-json-at-all')" \
  "relative perf ledger path with non-JSON content → DENY" "not parseable JSON"

rm -f "$LEDGER_PATH"
