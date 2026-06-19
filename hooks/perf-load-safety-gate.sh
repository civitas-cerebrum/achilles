#!/bin/bash
# perf-load-safety-gate.sh — hard ceiling on autonomous k6 load runs
#
# Hook    : PreToolUse:Bash  (filters to `k6 run` invocations)
# Mode    : DENY (VU ceiling, duration ceiling, allowlist, prod guard)
# State   : reads tests/perf/perf-onboarding.config.json
# Env     : none
#
# Why
# ---
# The perf-onboarding orchestrator runs fully autonomously and treats load
# caps as adjustable config defaults. To keep "autonomous" from meaning
# "unbounded" this gate enforces:
#   1. A HARD VU ceiling of 1000 baked into the gate (not read from config).
#   2. A HARD duration ceiling of 3600 seconds / 1 h (same).
#   3. An allowlist: only origins declared in targets.allowlist of the
#      perf-onboarding config file may be load-tested.
#   4. A production guard: the configured production origin cannot be
#      load-tested unless production.allowed is explicitly true.
#
# Because the gate lives at the Bash tool boundary, the agent cannot edit
# past it to raise the ceiling or bypass the allowlist.
#
# Failure → action
# ----------------
# Non-k6-run Bash                         → silent allow
# k6 run + VUs > 1000                     → DENY (hard ceiling)
# k6 run + duration > 3600s              → DENY (hard ceiling)
# k6 run + origin not in allowlist        → DENY
# k6 run + prod origin + allowed != true  → DENY
# k6 run + config missing                 → DENY (scaffold first)
# All checks pass                         → silent allow

# Intentional: `set -uo pipefail` without `-e`. Input-tolerant by design.
set -uo pipefail

# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH. Reinstall the package or install jq manually." >&2
  exit 1
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

# Only act on Bash tool invocations.
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only act on `k6 run` invocations.
# A real invocation appears at:
#   - start of the command line, optionally after env var assignments
#   - after a command separator (;, &&, ||, |)
# NOT inside a quoted string — those are preceded by " or '.
# This mirrors the playwright-cli-isolation-guard approach.
RUNNERS_K6='(env[[:space:]]+[A-Z_]+=\S+[[:space:]]+)?'
SEP_K6='(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*|\|[[:space:]]*)'
if ! echo "$CMD" | grep -qE "${SEP_K6}${RUNNERS_K6}k6[[:space:]]+run[[:space:]]"; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: emit a PreToolUse deny payload with the supplied reason.
# ---------------------------------------------------------------------------
emit_deny() {
  local reason="$1"
  "$JQ" -n --arg r "$reason" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# ---------------------------------------------------------------------------
# Resolve repo root from .cwd (same pattern as onboarding-ledger-gate.sh).
# ---------------------------------------------------------------------------
GATE_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(git -C "$GATE_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GATE_CWD")
CONFIG="$REPO_ROOT/tests/perf/perf-onboarding.config.json"

# ---------------------------------------------------------------------------
# Guard: config must exist (scaffold phase must have run first).
# ---------------------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
  emit_deny "[BLOCKED] perf load run attempted but tests/perf/perf-onboarding.config.json is missing — run perf-onboarding Phase 1 (Scaffold) first to establish the target allowlist + caps."
  exit 0
fi

# ---------------------------------------------------------------------------
# HARD CEILING CHECK 1: VUs
# Baked into the gate — NOT read from config — so the agent cannot raise it
# by editing the config file.
# ---------------------------------------------------------------------------
HARD_MAX_VUS=1000
HARD_MAX_DURATION_SEC=3600

# Parse --vus=N / --vus N / -u N forms.
REQUESTED_VUS=""
REQUESTED_VUS=$(echo "$CMD" | grep -oE -- '--vus[= ][0-9]+' | grep -oE '[0-9]+' | head -1 || true)
if [ -z "$REQUESTED_VUS" ]; then
  REQUESTED_VUS=$(echo "$CMD" | grep -oE -- '-u[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
fi

if [ -n "$REQUESTED_VUS" ] && [ "$REQUESTED_VUS" -gt "$HARD_MAX_VUS" ] 2>/dev/null; then
  emit_deny "[BLOCKED] requested VUs (${REQUESTED_VUS}) exceed the hard ceiling of 1000 baked into perf-load-safety-gate.sh. This ceiling is not configurable — it caps autonomous blast radius."
  exit 0
fi

# ---------------------------------------------------------------------------
# HARD CEILING CHECK 2: Duration
# Accepts formats: <N>s, <N>m, <N>h — convert to seconds for comparison.
# ---------------------------------------------------------------------------
REQUESTED_DUR_RAW=""
REQUESTED_DUR_RAW=$(echo "$CMD" | grep -oE -- '--duration[= ][0-9]+[smh]' | grep -oE '[0-9]+[smh]' | head -1 || true)

if [ -n "$REQUESTED_DUR_RAW" ]; then
  DUR_NUM=$(echo "$REQUESTED_DUR_RAW" | grep -oE '[0-9]+')
  DUR_UNIT=$(echo "$REQUESTED_DUR_RAW" | grep -oE '[smh]$')
  case "$DUR_UNIT" in
    s) REQUESTED_DUR_SEC="$DUR_NUM" ;;
    m) REQUESTED_DUR_SEC=$((DUR_NUM * 60)) ;;
    h) REQUESTED_DUR_SEC=$((DUR_NUM * 3600)) ;;
    *) REQUESTED_DUR_SEC=0 ;;
  esac
  if [ "$REQUESTED_DUR_SEC" -gt "$HARD_MAX_DURATION_SEC" ] 2>/dev/null; then
    emit_deny "[BLOCKED] requested duration (${REQUESTED_DUR_RAW} = ${REQUESTED_DUR_SEC}s) exceeds the hard ceiling of 3600s / 1h baked into perf-load-safety-gate.sh. This ceiling is not configurable — it caps autonomous blast radius."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# ALLOWLIST CHECK: extract the load target origin from CMD.
# Priority: -e PERF_BASE_URL=<url> → first http(s):// URL in command.
# ---------------------------------------------------------------------------
TARGET_ORIGIN=""

# Look for -e PERF_BASE_URL=<url> or PERF_BASE_URL=<url> inline.
PERF_BASE_URL_RAW=$(echo "$CMD" | grep -oE 'PERF_BASE_URL=https?://[^[:space:]"'"'"']+' | head -1 | sed 's/PERF_BASE_URL=//' || true)
if [ -n "$PERF_BASE_URL_RAW" ]; then
  # Extract scheme://host[:port] (strip path).
  TARGET_ORIGIN=$(echo "$PERF_BASE_URL_RAW" | grep -oE 'https?://[^/]+' | head -1 || true)
fi

# Fallback: first http(s):// URL in CMD.
if [ -z "$TARGET_ORIGIN" ]; then
  FIRST_URL=$(echo "$CMD" | grep -oE 'https?://[^[:space:]"'"'"']+' | head -1 || true)
  if [ -n "$FIRST_URL" ]; then
    TARGET_ORIGIN=$(echo "$FIRST_URL" | grep -oE 'https?://[^/]+' | head -1 || true)
  fi
fi

if [ -z "$TARGET_ORIGIN" ]; then
  emit_deny "[BLOCKED] could not determine the load target origin from the k6 command; add an explicit -e PERF_BASE_URL=<allowlisted-origin> so the safety gate can verify the target is in the allowlist."
  exit 0
fi

# Read allowlist from config.
ALLOWLIST=$("$JQ" -r '.targets.allowlist[]? // empty' "$CONFIG" 2>/dev/null || true)

ORIGIN_ALLOWED=false
while IFS= read -r entry; do
  if [ "$entry" = "$TARGET_ORIGIN" ]; then
    ORIGIN_ALLOWED=true
    break
  fi
done <<< "$ALLOWLIST"

if [ "$ORIGIN_ALLOWED" != "true" ]; then
  emit_deny "[BLOCKED] perf load target ${TARGET_ORIGIN} is not in targets.allowlist of perf-onboarding.config.json. Add it explicitly before load-testing it."
  exit 0
fi

# ---------------------------------------------------------------------------
# PRODUCTION GUARD: if prod origin is configured, it requires explicit opt-in.
# ---------------------------------------------------------------------------
PROD_ORIGIN=$("$JQ" -r '.production.origin // empty' "$CONFIG" 2>/dev/null || true)
PROD_ALLOWED=$("$JQ" -r '.production.allowed // false' "$CONFIG" 2>/dev/null || echo "false")

if [ -n "$PROD_ORIGIN" ] && [ "$PROD_ORIGIN" = "$TARGET_ORIGIN" ] && [ "$PROD_ALLOWED" != "true" ]; then
  emit_deny "[BLOCKED] ${TARGET_ORIGIN} is the configured production origin and production.allowed is not true. Production load requires production.allowed:true in perf-onboarding.config.json (a deliberate config opt-in)."
  exit 0
fi

# All checks passed — silent allow.
exit 0
