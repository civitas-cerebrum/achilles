#!/bin/bash
# plumber.sh — the plumber role: an approval-gated repair role for the harness itself.
#
# The plumber exists for the failures the harness cannot recover from on its own: a ledger whose
# integrity chain no longer matches, a dispatch lock that blocks every subagent, an installed hook
# set that drifted from the package, a protected file the shell guards will not let anyone read.
# Every other role is refused those paths. The plumber gets them, and only after the user has
# asked for it in their own words.
#
# Lifecycle
#   1. The user types a message that names the plumber and approves it ("approve the plumber",
#      "go ahead and use the plumber"). UserPromptSubmit fires only for what the user typed, so an
#      agent cannot produce this event. plumber-approval-gate.sh records ONE approval.
#   2. The orchestrator dispatches `plumber-<slug>:` (subagent_type plumber, brief tagged
#      `<<kernel-mandate-role: plumber#<nonce>>>`). plumber-approval-gate.sh consumes the
#      approval and opens a grant for PLUMBER_TTL_S seconds. No approval: the dispatch is denied.
#   3. While a grant is open, a caller the kernel resolves to role `plumber` is exempt from the
#      lock gates (plumber_caller_is_plumber). Everything it does is appended to the audit log.
#   4. A plumber write to a pipeline ledger must add an approvedDeviations[] entry whose
#      deviation starts with `plumber-repair:` and whose authorizer quotes the approval.
#
# Never exempted, even for the plumber: the session-activation state (.claude/achilles), which
# holds the approvals and grants, and the kernel manifest. A plumber cannot approve itself,
# extend its grant, or erase its trail.
#
# Requires lib/hook-io.sh (JQ set) and lib/achilles-activation.sh.

PLUMBER_TTL_S=3600
PLUMBER_ROLE=plumber

plumber__dir() { achilles__state_dir; }

# plumber__project_root <input-json> — CLAUDE_PROJECT_DIR, else the git top level of the call's
# cwd, else the cwd.
plumber__project_root() {
  local cwd top
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return 0; fi
  cwd=$(hook_json_str "$1" .cwd); [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=""
  printf '%s' "${top:-$cwd}"
}

plumber_log_path() { printf '%s/.claude/achilles/plumber-log.jsonl' "$(plumber__project_root "$1")"; }

# plumber_prompt_is_approval <text> — 0 when <text> names the plumber and approves it.
# Pasted blocks are not the user's own words and are dropped first. A negation anywhere refuses
# ("don't use the plumber", "no plumber"): an ambiguous message is not an approval.
plumber_prompt_is_approval() {
  local t
  t=$(printf '%s' "$1" | LC_ALL=C awk '
    /<pasted_content[^>]*>/ { skip = 1 }
    !skip { print }
    /<\/pasted_content>/ { skip = 0 }' | sed "s/’/'/g; s/‘/'/g" | tr '[:upper:]' '[:lower:]' | tr '\n\t' '  ')
  printf '%s' "$t" | grep -qE '(^|[^a-z])plumbers?([^a-z]|$)' || return 1
  printf '%s' "$t" | grep -qE "(^|[^a-z])(don'?t|do not|dont|never|no|not|stop|deny|denied|cancel|without|refuse|disallow|revoke)([^a-z]|$)" && return 1
  printf '%s' "$t" | grep -qE "(^|[^a-z])(approve[ds]?|approval|authori[sz]e[ds]?|allow(ed)?|go ahead|proceed|yes|ok|okay|use|dispatch|run|call|send|bring|let|need|want|fix|repair|unblock|unlock)([^a-z]|$)"
}

# plumber_record_approval <session_id> <prompt> — store one pending approval for this session.
plumber_record_approval() {
  local sid="$1" dir
  [ -n "$sid" ] || return 1
  dir="$(plumber__dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  "$JQ" -n --arg text "$2" --argjson ts "$(date +%s)" '{text: $text, ts: $ts}' > "$dir/$sid.plumber-approval.json.tmp" 2>/dev/null &&
    mv "$dir/$sid.plumber-approval.json.tmp" "$dir/$sid.plumber-approval.json"
}

# plumber_pending_approval <session_id> — print the pending approval text; 1 when none is live.
plumber_pending_approval() {
  local f ts
  f="$(plumber__dir)/$1.plumber-approval.json"
  [ -n "$1" ] && [ -f "$f" ] || return 1
  ts=$("$JQ" -r '.ts // 0' "$f" 2>/dev/null || echo 0)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ $(( $(date +%s) - ts )) -le "$PLUMBER_TTL_S" ] || { rm -f "$f"; return 1; }
  "$JQ" -r '.text // empty' "$f" 2>/dev/null
}

# plumber_consume_approval <session_id> <dispatch-id> — turn the pending approval into a grant.
# Single use: the approval is removed. Prints the approval text.
plumber_consume_approval() {
  local sid="$1" id="$2" text dir now grants prior="[]"
  text=$(plumber_pending_approval "$sid") || return 1
  dir="$(plumber__dir)"; now=$(date +%s)
  grants="$dir/plumber-grants.json"
  [ -f "$grants" ] && prior=$(cat "$grants" 2>/dev/null || echo "[]")
  printf '%s' "$prior" | "$JQ" -c \
    --arg id "$id" --arg sid "$sid" --arg text "$text" --argjson now "$now" --argjson ttl "$PLUMBER_TTL_S" '
      (if type == "array" then . else [] end)
      | map(select((.ts // 0) >= ($now - $ttl)))
      | . + [{id: $id, session: $sid, approval: $text, ts: $now}]' > "$grants.tmp" 2>/dev/null &&
    mv "$grants.tmp" "$grants" || { rm -f "$grants.tmp"; return 1; }
  rm -f "$dir/$sid.plumber-approval.json"
  printf '%s' "$text"
}

# plumber_live_grant — print the approval text of the newest open grant; 1 when none is open.
plumber_live_grant() {
  local grants text
  grants="$(plumber__dir)/plumber-grants.json"
  [ -f "$grants" ] || return 1
  text=$("$JQ" -r --argjson now "$(date +%s)" --argjson ttl "$PLUMBER_TTL_S" '
    [.[]? | select((.ts // 0) >= ($now - $ttl))] | last | .approval // empty' "$grants" 2>/dev/null)
  [ -n "$text" ] || return 1
  printf '%s' "$text"
}

# plumber_grant_for <dispatch-id> — 0 when an open grant was opened by this dispatch.
plumber_grant_for() {
  local grants
  grants="$(plumber__dir)/plumber-grants.json"
  [ -n "$1" ] && [ -f "$grants" ] || return 1
  "$JQ" -e --arg id "$1" --argjson now "$(date +%s)" --argjson ttl "$PLUMBER_TTL_S" '
    any(.[]?; .id == $id and (.ts // 0) >= ($now - $ttl))' "$grants" >/dev/null 2>&1
}

# plumber_caller_role <input-json> — the role the vendored kernel resolves for this call, or
# nothing. Runs in a subshell: the kernel library may emit its own deny and exit, which must not
# leak into the calling gate.
plumber_caller_role() {
  local lib out
  lib="$HOOK_IO_DIR/kernel-mandate.sh"
  [ -r "$lib" ] || return 1
  out=$(
    # shellcheck disable=SC1090
    . "$lib" >/dev/null 2>&1 || exit 1
    kernel_mandate_load "$1" >/dev/null 2>&1 || exit 1
    kernel_mandate_resolve_role >/dev/null 2>&1 || exit 1
    printf '\nKM_ROLE=%s' "${KM_ROLE:-}"
  ) || return 1
  printf '%s' "${out##*KM_ROLE=}"
}

# plumber_caller_is_plumber <input-json> — 0 when the caller is a subagent the kernel binds to the
# plumber role AND a grant is open. The main session is never the plumber.
plumber_caller_is_plumber() {
  [ -n "$(hook_json_str "$1" .agent_id)" ] || return 1
  plumber_live_grant >/dev/null || return 1
  [ "$(plumber_caller_role "$1")" = "$PLUMBER_ROLE" ]
}

# plumber_audit <input-json> <event> [detail] — append one line to the project's plumber log.
plumber_audit() {
  local log target
  log="$(plumber_log_path "$1")"
  mkdir -p "${log%/*}" 2>/dev/null || return 0
  target=$(hook_json_str "$1" .tool_input.file_path)
  [ -n "$target" ] || target=$(hook_json_str "$1" .tool_input.command)
  [ -n "$target" ] || target=$(hook_json_str "$1" .tool_input.description)
  "$JQ" -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$2" --arg detail "${3:-}" \
    --arg session "$(hook_json_str "$1" .session_id)" --arg agent "$(hook_json_str "$1" .agent_id)" \
    --arg tool "$(hook_json_str "$1" .tool_name)" --arg target "$target" \
    --arg approval "$(plumber_live_grant 2>/dev/null || true)" \
    '{ts: $ts, event: $event, session: $session, agent: $agent, tool: $tool, target: $target, approval: $approval, detail: $detail}' \
    >> "$log" 2>/dev/null || true
}

# plumber_exempt <input-json> <gate-name> — 0 (and an audit line) when this call is the approved
# plumber's; the calling gate then allows. 1 otherwise.
plumber_exempt() {
  plumber_caller_is_plumber "$1" || return 1
  plumber_audit "$1" exempted "$2"
  return 0
}

# plumber_targets_root_of_trust <path> — 0 for the paths no role, the plumber included, may write:
# the session-activation state (approvals, grants, audit log) and the kernel manifest.
plumber_targets_root_of_trust() {
  case "/${1#/}" in
    */.claude/achilles|*/.claude/achilles/*|*/.claude/kernel-mandate.json) return 0 ;;
  esac
  return 1
}
