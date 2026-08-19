# achilles-activation.sh — single source of truth for session-scoped
# protocol activation and its lifecycle.
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
# Lifecycle contract (one-way once active)
# ----------------------------------------
# A session activates at the FIRST achilles signal and then stays active
# for its whole lifetime. The ONLY two deactivation paths are:
#   1. the pipeline completes — the activation watcher observes a
#      sanctioned ledger write that lands a terminal pipeline status
#      ("complete" / "aborted") and retires the session marker, or
#   2. the Claude session is terminated by the user.
# There is no mid-session off switch. In particular:
#   - ACHILLES_PROTOCOL=0 prevents a session from ACTIVATING but does NOT
#     deactivate a session whose marker already exists — the marker wins.
#   - The marker state dir (~/.claude/achilles/) is a protected artifact:
#     protected-artifact-bash-guard denies Bash mutations of it and
#     harness-self-protection-guard denies Write|Edit to it,
#     UNCONDITIONALLY (even in otherwise-inactive sessions) — the
#     activation state is the root of trust for every other gate.
# Deny payloads carry achilles_scope_notice() so both the agent and the
# user learn the sanctioned way out: finish the pipeline or kill the
# session and start a fresh one for unrelated work.
#
# Activation signals (checked in order)
# -------------------------------------
#   1. ACHILLES_PROTOCOL=1|true|on|active → ACTIVE (forced on).
#   2. Missing/empty session_id in the hook input → ACTIVE (fail closed)
#      unless ACHILLES_PROTOCOL=0. A real harness always supplies
#      session_id; an input without one is a synthetic invocation (test
#      fixture, replayed payload, older harness) and the guards stay
#      protective rather than being trivially bypassable by stripping a
#      field.
#   3. Session marker <sid>.active exists → ACTIVE. Beats everything,
#      including ACHILLES_PROTOCOL=0 (one-way lifecycle, see above).
#   4. ACHILLES_PROTOCOL=0|false|off → INACTIVE (activation suppressed).
#   5. Completion marker <sid>.completed exists → the pipeline finished
#      earlier in this session. Only an explicit protocol-shaped CURRENT
#      call re-activates (fresh Skill invocation / role-prefixed
#      dispatch, which clears the completion marker); the transcript scan
#      is suppressed because historical signatures from the completed run
#      would otherwise re-activate forever. Otherwise INACTIVE.
#   6. The CURRENT tool call is protocol-shaped (Skill invocation of an
#      achilles skill, or an Agent dispatch whose description carries a
#      distinctly-achilles role prefix) → ACTIVE. This closes the race on
#      the very first activating call: sibling hooks in the same matcher
#      group see the same input and reach the same verdict without
#      depending on watcher ordering.
#   7. The session transcript contains an activation signature (a Skill
#      tool_use naming an achilles skill, a typed /<skill> command, or a
#      Read of an achilles SKILL.md) → ACTIVE. Covers subagent contexts
#      and resumed sessions where the activating call predates the
#      current one. Negative results are cached for 60s per session.
#   8. Otherwise → INACTIVE (dev session; every gate silent-allows).
#
# Signals 6 and 7 write the marker (when session_id is known) so the scan
# runs at most once per session per outcome change.
#
# False-positive direction (accepted, documented): the transcript scan is
# a raw grep, so a session that merely QUOTES an activation signature
# (e.g. a dev pasting '"skill":"onboarding"' or editing
# skills/onboarding/SKILL.md paths) activates the guards. That errs
# protective; the way out is completing the pipeline or ending the
# session.
#
# Caller contract
# ---------------
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
#   achilles_require_active "$INPUT"    # exits 0 (silent allow) if inactive
#
# Reporting/cleanup hooks that must still run after pipeline completion
# (summary writers, browser cleanup) use:
#   achilles_require_active_or_completed "$INPUT"
#
# The lib uses $JQ when the caller has already resolved it, otherwise
# resolves its own (bundled bin/jq, then PATH).

# Skill names bundled by this package (skills/<name>/). Any Skill
# invocation of one of these — bare or plugin/path-prefixed — activates
# the protocol for the session.
#
# Orchestrator aliases. This alternation is the ONLY place any skill name
# keys activation (both the Skill-name match in
# achilles__current_call_signature and the `skills/<name>/SKILL.md`
# transcript grep read it), so a name the alternation does not know is a
# name that silently activates nothing — every guard in the suite stays
# off, which is a fail-open.
#
# `achilles-protocol` is the orchestrator skill's name as of the rename
# from `element-interactions`. `element-interactions` is retained below
# as a backward-compat alias so installs still carrying the old skill
# directory keep activating — do not drop it. An install that predates
# the rename would otherwise lose every guard silently, and losing
# guards silently is precisely the failure this alternation exists to
# prevent.
#
# NOTE: `element-interactions` in this list is the OLD SKILL name, not
# the npm package. `@civitas-cerebrum/element-interactions` is the
# Playwright interaction library — a separate thing, not renamed.
ACHILLES_SKILL_ALT='achilles-protocol|agents-vs-agents|bug-discovery|bug-report|companion-mode|ticket-driven-testing|self-repair|contract-testing|contributing-to-achilles-protocol|coverage-expansion|database-testing|element-interactions|failure-diagnosis|journey-mapping|onboarding|perf-onboarding|performance-testing|secrets-sweep|selector-development|test-catalogue|test-composer|test-repair|work-summary-deck|workflow-reviewer'

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

# achilles_scope_notice
# Canonical lifecycle block appended to every deny payload. Tells both the
# agent and the user the sanctioned exits: pipeline completion or session
# termination. Emitted with a leading blank line so callers can append it
# directly to an existing reason string.
achilles_scope_notice() {
  printf '\n\n%s' '── achilles session-scope ──────────────────────────────
These guardrails are bound to the achilles protocol activated in this
session. Once activated, the protocol CANNOT be switched off mid-session:
it ends only when the pipeline completes (terminal ledger status
"complete" / "aborted") or when this Claude session is terminated. Do not
try to strip session markers, rewrite hooks, or re-shape the call to slip
past — the activation state is itself a protected artifact.

To tackle an unrelated task or start a new workflow: END THIS SESSION and
start a fresh one. (Agent: relay this instruction to the user — killing
the session is their call, not yours.)'
}

# achilles_mark_session_active <session_id>
# Touches the session marker and clears any completion marker (an explicit
# fresh activation re-opens the protocol after an earlier completed run).
# Best-effort; never fails the caller.
achilles_mark_session_active() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  local dir
  dir="$(achilles__state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  : > "$dir/${sid}.active" 2>/dev/null || true
  rm -f "$dir/${sid}.completed" "$dir/${sid}.nohit" 2>/dev/null || true
  return 0
}

# achilles_mark_session_completed <session_id> [reason]
# Retires the active marker: the pipeline reached a terminal status. The
# session drops back to silent-allow for enforcement gates; reporting /
# cleanup hooks keep running via achilles_require_active_or_completed.
achilles_mark_session_completed() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  local dir
  dir="$(achilles__state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "${2:-pipeline-complete} $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/${sid}.completed" 2>/dev/null || true
  rm -f "$dir/${sid}.active" 2>/dev/null || true
  return 0
}

# achilles__current_call_signature <input-json> <jq-bin>
# Returns 0 when the current tool call is protocol-shaped.
achilles__current_call_signature() {
  local input="$1" jq_bin="$2" tool_name skill_name description
  tool_name=$(printf '%s' "$input" | "$jq_bin" -r '.tool_name // empty' 2>/dev/null || echo "")
  case "$tool_name" in
    Skill)
      skill_name=$(printf '%s' "$input" | "$jq_bin" -r '.tool_input.skill // empty' 2>/dev/null || echo "")
      printf '%s' "$skill_name" | grep -qE "(^|:)(${ACHILLES_SKILL_ALT})$" && return 0
      ;;
    Agent)
      description=$(printf '%s' "$input" | "$jq_bin" -r '.tool_input.description // empty' 2>/dev/null || echo "")
      printf '%s' "$description" | grep -qE "$ACHILLES_DISPATCH_PREFIX_RE" && return 0
      ;;
  esac
  return 1
}

# achilles_session_active <hook-input-json>
# Returns 0 when the achilles protocol is active for this session,
# 1 when this is a plain (non-achilles) session or a completed run.
achilles_session_active() {
  local input="$1"
  local jq_bin sid transcript env_off=0

  case "${ACHILLES_PROTOCOL:-}" in
    1|true|on|ON|active) return 0 ;;
    0|false|off|OFF) env_off=1 ;;
  esac

  jq_bin="$(achilles__jq)"
  # No jq → cannot inspect the input; stay protective (unless env-off).
  if [ -z "$jq_bin" ]; then
    [ "$env_off" = "1" ] && return 1
    return 0
  fi

  sid=$(printf '%s' "$input" | "$jq_bin" -r '.session_id // empty' 2>/dev/null || echo "")

  # Unidentifiable session context → fail closed (guards on), except under
  # the explicit env-off (test fixtures / synthetic payloads).
  if [ -z "$sid" ]; then
    [ "$env_off" = "1" ] && return 1
    return 0
  fi

  # Active marker: one-way — beats ACHILLES_PROTOCOL=0. Deactivation is
  # pipeline completion or session termination only.
  if [ -f "$(achilles__state_dir)/${sid}.active" ]; then
    return 0
  fi

  # Env-off suppresses every ACTIVATION path (but never a live marker).
  [ "$env_off" = "1" ] && return 1

  # Completed run: only an explicit fresh protocol-shaped call re-opens
  # the protocol; historical transcript signatures do not.
  if [ -f "$(achilles__state_dir)/${sid}.completed" ]; then
    if achilles__current_call_signature "$input" "$jq_bin"; then
      achilles_mark_session_active "$sid"
      return 0
    fi
    return 1
  fi

  # Current call is itself protocol-shaped.
  if achilles__current_call_signature "$input" "$jq_bin"; then
    achilles_mark_session_active "$sid"
    return 0
  fi

  # Transcript scan for an activation signature. Negative results are
  # cached for 60s per session (dirs with many gated hooks would
  # otherwise re-grep the transcript once per hook per tool call in
  # long-running dev sessions). The cache only delays the
  # transcript-fallback path — the watcher and the current-call check
  # mark activation immediately, bypassing it.
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
      achilles_mark_session_active "$sid"
      return 0
    fi
  fi

  # Plain dev session — stamp the negative cache (best-effort).
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

# achilles_require_active_or_completed <hook-input-json>
# For reporting / cleanup hooks (summary writers, browser reaping) that
# must still run after the pipeline completed in this session: proceeds
# when the session is active OR carries a completion marker; silent-allows
# (exit 0) in plain dev sessions.
achilles_require_active_or_completed() {
  local input="$1" jq_bin sid
  if achilles_session_active "$input"; then
    return 0
  fi
  jq_bin="$(achilles__jq)"
  if [ -n "$jq_bin" ]; then
    sid=$(printf '%s' "$input" | "$jq_bin" -r '.session_id // empty' 2>/dev/null || echo "")
    if [ -n "$sid" ] && [ -f "$(achilles__state_dir)/${sid}.completed" ]; then
      return 0
    fi
  fi
  exit 0
}
