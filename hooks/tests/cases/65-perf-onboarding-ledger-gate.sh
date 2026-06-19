#!/bin/bash
# Tests for perf-onboarding-ledger-gate.sh — pipeline state-machine enforcement
# for the perf-onboarding workflow. PreToolUse:Agent. DENY mode.
H="$HOOK_DIR/perf-onboarding-ledger-gate.sh"

TMP_REPO=$(mktemp -d /tmp/perf-ledger-gate-XXXXXX)
mkdir -p "$TMP_REPO/tests/perf/docs"
(cd "$TMP_REPO" && git init -q && git config user.email t@t && git config user.name t)
trap 'rm -rf "$TMP_REPO"' EXIT

LEDGER="$TMP_REPO/tests/perf/docs/perf-onboarding-status.json"

write_ledger() { printf '%s' "$1" > "$LEDGER"; }
clear_ledger() { rm -f "$LEDGER"; }

# Baseline valid perf ledger (7 phases).
fresh_perf_ledger_json='{
  "schemaVersion": 1,
  "pipelineVersion": "0.1.0",
  "runMode": "standard",
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
section "perf-ledger-gate: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls')" "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Read file_path='/tmp/x')" "Read → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path='/tmp/x' content='y')" "Write → silent allow"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: missing ledger silent-allows (fresh run)"
clear_ledger
assert_allow "$H" "$(payload tool_name=Agent description='scaffold-perf-config' prompt='Set up perf config.' cwd="$TMP_REPO")" \
  "scaffold-perf dispatch with no perf ledger → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='readiness-check' prompt='Check k6 available.' cwd="$TMP_REPO")" \
  "readiness dispatch with no perf ledger → silent allow"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: malformed ledger silent-allows"
write_ledger 'not-json-at-all'
assert_allow "$H" "$(payload tool_name=Agent description='readiness-probe' prompt='Probe.' cwd="$TMP_REPO")" \
  "dispatch with non-JSON perf ledger → silent allow"
write_ledger '{"no-schema-version": true}'
assert_allow "$H" "$(payload tool_name=Agent description='readiness-probe' prompt='Probe.' cwd="$TMP_REPO")" \
  "dispatch with schema-less perf ledger → silent allow"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: perf-reviewer-* dispatches ALWAYS allowed"
# Even with a pending-verdict transition point.
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "pending" |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"}
')"
assert_allow "$H" "$(payload tool_name=Agent description='perf-reviewer-phase1: review Phase 1 scaffold exit criteria' prompt='Validate.' cwd="$TMP_REPO")" \
  "perf-reviewer-phase1 at transition point → ALLOW"
assert_allow "$H" "$(payload tool_name=Agent description='perf-reviewer-phase2: review readiness' prompt='Review.' cwd="$TMP_REPO")" \
  "perf-reviewer-phase2 → ALLOW"
assert_allow "$H" "$(payload tool_name=Agent description='perf-reviewer-pass-load: review load pass' prompt='Review.' cwd="$TMP_REPO")" \
  "perf-reviewer-pass-load → ALLOW"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: transition-point forces perf-reviewer-* dispatch"
# Phase 1 completed but verdict pending → non-reviewer dispatch DENIED.
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "pending" |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"}
')"
assert_deny "$H" "$(payload tool_name=Agent description='readiness-probe' prompt='Check k6.' cwd="$TMP_REPO")" \
  "readiness dispatch with phase-1 verdict pending → DENY" "perf-reviewer-phase1"
assert_deny "$H" "$(payload tool_name=Agent description='scenario-model-author' prompt='Author scenarios.' cwd="$TMP_REPO")" \
  "scenario-model dispatch with phase-1 verdict pending → DENY" "perf-reviewer-phase1"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: approved verdict allows next phase to begin"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "approved" |
  .phases[0].reviewerCycles = 1 |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"} |
  .phases[1].status = "in-progress"
')"
assert_allow "$H" "$(payload tool_name=Agent description='readiness-check-full' prompt='Full readiness check.' cwd="$TMP_REPO")" \
  "readiness dispatch after phase-1 approved → ALLOW"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: out-of-order phase dispatch DENIED"
# currentPhase=2, but a load-run-* dispatch jumps to phase 5.
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 2 |
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "approved" |
  .phases[0].handoverEnvelope = {"role":"scaffold-perf","status":"complete"} |
  .phases[1].status = "in-progress"
')"
assert_deny "$H" "$(payload tool_name=Agent description='load-run-load-scenario-auth:' prompt='Run load test.' cwd="$TMP_REPO")" \
  "load-run dispatch with currentPhase=2 → DENY" "Out-of-order phase dispatch"

# threshold-gate before phase 5 approved.
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 5 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress" | .phases[4].reviewerVerdict = "pending"
')"
assert_deny "$H" "$(payload tool_name=Agent description='threshold-gate-evaluate:' prompt='Evaluate thresholds.' cwd="$TMP_REPO")" \
  "threshold-gate dispatch with phase-5 not approved → DENY" "Out-of-order phase dispatch"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: Phase-5 pass ordering — stress denied while load pending"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 5 |
  .currentSubStage = "pass-stress" |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress" | .phases[4].subStages = [
    {"id":"pass-load","status":"completed","reviewerVerdict":"pending","reviewerCycles":0}
  ]
')"
assert_deny "$H" "$(payload tool_name=Agent description='load-run-stress-scenario-auth:' prompt='Run stress test.' cwd="$TMP_REPO")" \
  "stress pass dispatch with load pass verdict pending → DENY" "pass-load is not reviewer-approved"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: Phase-5 pass ordering — spike denied while stress pending"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 5 |
  .currentSubStage = "pass-spike" |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress" | .phases[4].subStages = [
    {"id":"pass-load","status":"completed","reviewerVerdict":"approved","reviewerCycles":1},
    {"id":"pass-stress","status":"completed","reviewerVerdict":"pending","reviewerCycles":0}
  ]
')"
assert_deny "$H" "$(payload tool_name=Agent description='load-run-spike-scenario:' prompt='Run spike test.' cwd="$TMP_REPO")" \
  "spike pass dispatch with stress pass verdict pending → DENY" "pass-stress is not reviewer-approved"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: Phase-5 first pass (load) allowed — no prior pass"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 5 |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress" | .phases[4].subStages = []
')"
assert_allow "$H" "$(payload tool_name=Agent description='load-run-load-k6-run:' prompt='Run first load pass.' cwd="$TMP_REPO")" \
  "load pass (first pass, no prior) → ALLOW"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: Phase-5 pass ordering — soak allowed after spike approved"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 5 |
  .currentSubStage = "pass-soak" |
  .phases[0].status = "completed" | .phases[0].reviewerVerdict = "approved" | .phases[0].handoverEnvelope = {} |
  .phases[1].status = "completed" | .phases[1].reviewerVerdict = "approved" | .phases[1].handoverEnvelope = {} |
  .phases[2].status = "completed" | .phases[2].reviewerVerdict = "approved" | .phases[2].handoverEnvelope = {} |
  .phases[3].status = "completed" | .phases[3].reviewerVerdict = "approved" | .phases[3].handoverEnvelope = {} |
  .phases[4].status = "in-progress" | .phases[4].subStages = [
    {"id":"pass-load","status":"completed","reviewerVerdict":"approved","reviewerCycles":1},
    {"id":"pass-stress","status":"completed","reviewerVerdict":"approved","reviewerCycles":1},
    {"id":"pass-spike","status":"completed","reviewerVerdict":"approved","reviewerCycles":1}
  ]
')"
assert_allow "$H" "$(payload tool_name=Agent description='load-run-soak-72h-run:' prompt='Run soak test.' cwd="$TMP_REPO")" \
  "soak pass dispatch after spike approved → ALLOW"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: reviewerCycles cap denies 4th perf-reviewer dispatch"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "rejected" |
  .phases[0].reviewerCycles = 3
')"
assert_deny "$H" "$(payload tool_name=Agent description='perf-reviewer-phase1: re-review Phase 1 scaffold' prompt='Review again.' cwd="$TMP_REPO")" \
  "perf-reviewer dispatch at reviewerCycles=3 (rejected) → DENY (cap)" "reviewerCycles is already 3"

# Escalated → cap exemption satisfied.
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .phases[0].status = "completed" |
  .phases[0].reviewerVerdict = "escalated-to-user" |
  .phases[0].reviewerCycles = 3 |
  .status = "blocked"
')"
assert_allow "$H" "$(payload tool_name=Agent description='perf-reviewer-phase1: confirm escalation' prompt='Confirm.' cwd="$TMP_REPO")" \
  "perf-reviewer dispatch at reviewerCycles=3 (escalated-to-user) → ALLOW"

# ---------------------------------------------------------------------------
section "perf-ledger-gate: free-form prefixes silent-allow when no transition point"
write_ledger "$(echo "$fresh_perf_ledger_json" | "$JQ" '
  .currentPhase = 1 |
  .phases[0].status = "in-progress" |
  .phases[0].reviewerVerdict = "pending"
')"
assert_allow "$H" "$(payload tool_name=Agent description='cleanup-perf-results' prompt='Dedup.' cwd="$TMP_REPO")" \
  "cleanup-* during phase-1 in-progress (no transition point) → ALLOW"

clear_ledger
