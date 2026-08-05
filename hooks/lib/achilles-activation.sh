# achilles-activation.sh — single source of truth for session-scoped
# protocol activation.
#
# Why
# ---
# The harness hooks are installed GLOBALLY (~/.claude/settings.json), so
# historically they fired in every Claude Code session on the machine —
# including plain development sessions that never touch the achilles
# methodology. That is wrong scoping: the guardrails exist to protect the
# METHODOLOGY's artifacts and conventions (ledgers, journey maps, commit
# grammar, reviewer separation-of-duties), not to police unrelated dev
# work. This lib gives every gate a shared answer to the question "is the
# achilles protocol actually in play in THIS session?" so gates can
# silent-allow everywhere else.
#
# Activation signals (checked in order)
# -------------------------------------
#   1. ACHILLES_PROTOCOL env override:
#        0|false|off      → INACTIVE (hard off — wins over everything)
#        1|true|on|active → ACTIVE
#   2. Missing/empty session_id in the hook input → ACTIVE (fail closed).
#      A real harness always supplies session_id; an input without one is
#      a synthetic invocation (test fixture, replayed payload, older
#      harness) and the guards stay protective rather than being
#      trivially bypassable by stripping a field.
#   3. Session marker file exists → ACTIVE. Markers live at
#      $ACHILLES_SESSION_STATE_DIR/<session_id>.active (default
#      ~/.claude/achilles/sessions/) and are written by the activation
#      watcher hook the moment an achilles skill / role-prefixed dispatch
#      appears, then reused by every subsequent gate as a cheap cache.
#   4. The CURRENT tool call is protocol-shaped (Skill invocation of an
#      achilles skill, or an Agent dispatch whose description carries a
#      distinctly-achilles role prefix) → ACTIVE. This closes the race on
#      the very first activating call: sibling hooks in the same matcher
#      group see the same input and reach the same verdict without
#      depending on watcher ordering.
#   5. The session transcript contains an activation signature (a Skill
#      tool_use naming an achilles skill, a typed /<skill> command, or a
#      Read of an achilles SKILL.md) → ACTIVE. Covers subagent contexts
#      and resumed sessions where the activating call predates the
#      current one.
#   6. Otherwise → INACTIVE (dev session; every gate silent-allows).
#
# Signals 4 and 5 write the marker (when session_id is known) so the scan
# runs at most once per session per outcome change.
#
# False-positive direction (accepted, documented): the transcript scan is
# a raw grep, so a session that merely QUOTES an activation signature
# (e.g. a dev pasting '"skill":"onboarding"' or editing
# skills/onboarding/SKILL.md paths) activates the guards. That errs
# protective; ACHILLES_PROTOCOL=0 is the documented hard off.
#
# Caller contract
# ---------------
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
#   achilles_require_active "$INPUT"    # exits 0 (silent allow) if inactive
#
# The lib uses $JQ when the caller has already resolved it, otherwise
# resolves its own (bundled bin/jq, then PATH).

# Skill names bundled by this package (skills/<name>/). Any Skill
# invocation of one of these — bare or plugin/path-prefixed — activates
# the protocol for the session.
ACHILLES_SKILL_ALT='agents-vs-agents|bug-discovery|bug-report|companion-mode|contract-testing|contributing-to-element-interactions|coverage-expansion|database-testing|element-interactions|failure-diagnosis|journey-mapping|onboarding|perf-onboarding|performance-testing|secrets-sweep|selector-development|test-catalogue|test-composer|test-repair|work-summary-deck|workflow-reviewer'

# Distinctly-achilles subagent description prefixes (backstop for briefs
# issued without a prior Skill call, e.g. external CLI drivers). Kept to
# prefixes that are unambiguous protocol vocabulary — generic-sounding
# ones from schema-role-map.sh (cleanup-, companion-, phase1-, stage2-,
# reviewer-, fd-) are deliberately excluded: a dev's "cleanup-temp:" agent
# must not switch the guards on. Genuine protocol runs activate via the
# skill signals anyway.
ACHILLES_DISPATCH_PREFIX_RE='^[[:space:]]*(workflow-reviewer-|perf-reviewer-|phase-validator-|phase4-cycle-|phase4-prioritise-author|composer-|probe-|process-validator-|contribution-handover-)'

achilles__jq() {
  if [ -n "${JQ:-}" ] && [ -x "${JQ:-}" ]; then
    printf '%s' "$JQ"
    return 0
  fi
  local candidate
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/jq"
  if [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  command -v jq || true
}

achilles__state_dir() {
  printf '%s' "${ACHILLES_SESSION_STATE_DIR:-$HOME/.claude/achilles/sessions}"
}

# achilles_mark_session_active <session_id>
# Touches the session marker (best-effort; never fails the caller).
achilles_mark_session_active() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  local dir
  dir="$(achilles__state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  : > "$dir/${sid}.active" 2>/dev/null || true
  return 0
}

# achilles_session_active <hook-input-json>
# Returns 0 when the achilles protocol is active for this session,
# 1 when this is a plain (non-achilles) session.
achilles_session_active() {
  local input="$1"
  local jq_bin sid transcript

  # 1. Explicit env override — both directions.
  case "${ACHILLES_PROTOCOL:-}" in
    0|false|off|OFF) return 1 ;;
    1|true|on|ON|active) return 0 ;;
  esac

  jq_bin="$(achilles__jq)"
  # No jq → cannot inspect the input; stay protective.
  [ -n "$jq_bin" ] || return 0

  sid=$(printf '%s' "$input" | "$jq_bin" -r '.session_id // empty' 2>/dev/null || echo "")

  # 2. Unidentifiable session context → fail closed (guards stay on).
  [ -n "$sid" ] || return 0

  # 3. Cached marker.
  if [ -f "$(achilles__state_dir)/${sid}.active" ]; then
    return 0
  fi

  # 4. Current call is itself protocol-shaped.
  local tool_name skill_name description
  tool_name=$(printf '%s' "$input" | "$jq_bin" -r '.tool_name // empty' 2>/dev/null || echo "")
  case "$tool_name" in
    Skill)
      skill_name=$(printf '%s' "$input" | "$jq_bin" -r '.tool_input.skill // empty' 2>/dev/null || echo "")
      if printf '%s' "$skill_name" | grep -qE "(^|:)(${ACHILLES_SKILL_ALT})$"; then
        achilles_mark_session_active "$sid"
        return 0
      fi
      ;;
    Agent)
      description=$(printf '%s' "$input" | "$jq_bin" -r '.tool_input.description // empty' 2>/dev/null || echo "")
      if printf '%s' "$description" | grep -qE "$ACHILLES_DISPATCH_PREFIX_RE"; then
        achilles_mark_session_active "$sid"
        return 0
      fi
      ;;
  esac

  # 5. Transcript scan for an activation signature. Negative results are
  #    cached for 60s per session (dirs with many gated hooks would
  #    otherwise re-grep the transcript once per hook per tool call in
  #    long-running dev sessions). The cache only delays the
  #    transcript-fallback path — the watcher and signal 4 mark
  #    activation immediately, bypassing it.
  local nohit nohit_ts now_ts
  nohit="$(achilles__state_dir)/${sid}.nohit"
  if [ -f "$nohit" ]; then
    nohit_ts=$(head -1 "$nohit" 2>/dev/null || echo 0)
    case "$nohit_ts" in ''|*[!0-9]*) nohit_ts=0 ;; esac
    now_ts=$(date +%s)
    if [ $((now_ts - nohit_ts)) -lt 60 ]; then
      return 1
    fi
  fi
  transcript=$(printf '%s' "$input" | "$jq_bin" -r '.transcript_path // empty' 2>/dev/null || echo "")
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    if grep -qE "\"skill\"[[:space:]]*:[[:space:]]*\"([a-z0-9./_-]+:)?(${ACHILLES_SKILL_ALT})\"|<command-name>/(${ACHILLES_SKILL_ALT})<|skills/(${ACHILLES_SKILL_ALT})/SKILL\.md" "$transcript" 2>/dev/null; then
      rm -f "$nohit" 2>/dev/null || true
      achilles_mark_session_active "$sid"
      return 0
    fi
  fi

  # 6. Plain dev session — stamp the negative cache (best-effort).
  mkdir -p "$(achilles__state_dir)" 2>/dev/null && date +%s > "$nohit" 2>/dev/null || true
  return 1
}

# achilles_require_active <hook-input-json>
# Silent-allows (exit 0) the calling hook when the protocol is inactive.
achilles_require_active() {
  if ! achilles_session_active "$1"; then
    exit 0
  fi
  return 0
}
