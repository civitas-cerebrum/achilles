#!/bin/bash
# Tests for perf-load-safety-gate.sh — k6 load run blast-radius enforcer.
# PreToolUse:Bash. DENY mode.
H="$HOOK_DIR/perf-load-safety-gate.sh"

# ---------------------------------------------------------------------------
# Temp repo + config setup.
# The gate resolves the repo root from .cwd and reads
# tests/perf/perf-onboarding.config.json from there.
# ---------------------------------------------------------------------------
TMP_REPO=$(mktemp -d /tmp/perf-load-safety-gate-XXXXXX)
mkdir -p "$TMP_REPO/tests/perf"
(cd "$TMP_REPO" && git init -q && git config user.email t@t && git config user.name t)
trap 'rm -rf "$TMP_REPO"' EXIT

CONFIG="$TMP_REPO/tests/perf/perf-onboarding.config.json"

write_config() {
  printf '%s' "$1" > "$CONFIG"
}

clear_config() {
  rm -f "$CONFIG"
}

# Baseline config: one allowlisted staging origin, no production entry.
BASELINE_CONFIG='{
  "targets": {
    "allowlist": ["http://localhost:3000", "https://staging.example.com"]
  }
}'

# Config with a production guard (allowed:false by default).
PROD_CONFIG='{
  "targets": {
    "allowlist": ["https://staging.example.com", "https://prod.example.com"]
  },
  "production": {
    "origin": "https://prod.example.com",
    "allowed": false
  }
}'

# Config with production.allowed:true (explicit opt-in).
PROD_ALLOWED_CONFIG='{
  "targets": {
    "allowlist": ["https://staging.example.com", "https://prod.example.com"]
  },
  "production": {
    "origin": "https://prod.example.com",
    "allowed": true
  }
}'

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: tool-name / command filtering"
# ---------------------------------------------------------------------------
write_config "$BASELINE_CONFIG"

assert_allow "$H" \
  "$(payload tool_name=Read file_path='/tmp/x')" \
  "Read tool → silent allow"

assert_allow "$H" \
  "$(payload tool_name=Bash command='npm test' cwd="$TMP_REPO")" \
  "non-k6 Bash command → silent allow"

assert_allow "$H" \
  "$(payload tool_name=Bash command='echo \"k6 run is fast\"' cwd="$TMP_REPO")" \
  "k6 run inside echo string → silent allow"

assert_allow "$H" \
  "$(payload tool_name=Bash command='cat k6-run-results.json' cwd="$TMP_REPO")" \
  "k6-run in filename (not an invocation) → silent allow"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: missing config → deny (scaffold first)"
# ---------------------------------------------------------------------------
clear_config

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run script.js' cwd="$TMP_REPO")" \
  "k6 run + missing config → DENY" \
  "perf-onboarding.config.json is missing"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 10 --duration 30s http://localhost:3000 script.js' cwd="$TMP_REPO")" \
  "k6 run with flags + missing config → DENY" \
  "Phase 1 (Scaffold)"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: hard VU ceiling (1000 VUs baked in)"
# ---------------------------------------------------------------------------
write_config "$BASELINE_CONFIG"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 2000 --duration 30s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--vus 2000 → DENY (hard ceiling)" \
  "hard ceiling of 1000"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus=1001 --duration 30s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--vus=1001 → DENY (one over ceiling)" \
  "hard ceiling of 1000"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run -u 5000 --duration 30s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "-u 5000 (short form) → DENY" \
  "hard ceiling of 1000"

# Exactly at the ceiling → ALLOW (ceiling is inclusive: > 1000 is denied).
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 1000 --duration 30s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--vus 1000 (at ceiling) → ALLOW"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: hard duration ceiling (3600s / 1h)"
# ---------------------------------------------------------------------------
write_config "$BASELINE_CONFIG"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --duration 2h script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--duration 2h → DENY (over 3600s)" \
  "hard ceiling of 3600s"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --duration=90m script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--duration=90m (5400s) → DENY" \
  "hard ceiling of 3600s"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --duration 3601s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--duration 3601s (one over ceiling) → DENY" \
  "hard ceiling of 3600s"

# Exactly at the ceiling → ALLOW.
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --duration 3600s script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--duration 3600s (at ceiling) → ALLOW"

assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --duration 60m script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--duration 60m (= 3600s, at ceiling) → ALLOW"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: allowlist enforcement"
# ---------------------------------------------------------------------------
write_config "$BASELINE_CONFIG"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=https://not-in-list.example.com' cwd="$TMP_REPO")" \
  "target not in allowlist → DENY" \
  "not in targets.allowlist"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m https://other.example.com/script.js' cwd="$TMP_REPO")" \
  "URL not in allowlist (extracted from command) → DENY" \
  "not in targets.allowlist"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js' cwd="$TMP_REPO")" \
  "no URL in command at all → DENY (conservative)" \
  "could not determine the load target origin"

# In-allowlist origin via PERF_BASE_URL → ALLOW.
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "in-allowlist localhost:3000 via PERF_BASE_URL → ALLOW"

assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=https://staging.example.com' cwd="$TMP_REPO")" \
  "in-allowlist staging.example.com via PERF_BASE_URL → ALLOW"

# In-allowlist origin extracted from the URL argument.
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m https://staging.example.com/script.js' cwd="$TMP_REPO")" \
  "in-allowlist staging.example.com from URL arg → ALLOW"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: production guard"
# ---------------------------------------------------------------------------
write_config "$PROD_CONFIG"

assert_deny "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=https://prod.example.com' cwd="$TMP_REPO")" \
  "prod origin + allowed:false → DENY" \
  "production origin and production.allowed is not true"

# Staging target with prod guard config → ALLOW (not the prod origin).
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=https://staging.example.com' cwd="$TMP_REPO")" \
  "staging target with prod config → ALLOW (not prod origin)"

write_config "$PROD_ALLOWED_CONFIG"

# production.allowed:true → explicit opt-in → ALLOW.
assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=https://prod.example.com' cwd="$TMP_REPO")" \
  "prod origin + allowed:true → ALLOW"

# ---------------------------------------------------------------------------
section "perf-load-safety-gate: combined checks (VU + duration + allowlist — happy path)"
# ---------------------------------------------------------------------------
write_config "$BASELINE_CONFIG"

assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 50 --duration 5m script.js -e PERF_BASE_URL=http://localhost:3000' cwd="$TMP_REPO")" \
  "--vus 50 --duration 5m in-allowlist → ALLOW (all checks pass)"

assert_allow "$H" \
  "$(payload tool_name=Bash command='k6 run --vus 200 --duration 30m script.js -e PERF_BASE_URL=https://staging.example.com' cwd="$TMP_REPO")" \
  "--vus 200 --duration 30m in-allowlist staging → ALLOW"
