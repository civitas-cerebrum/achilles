#!/bin/bash
# hook-io.sh — jq bootstrap, lib loading and hook-input access shared by every Achilles hook.
HOOK_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# hook_jq_init <fatal|silent|empty|continue> — set JQ (bundled, else PATH). Without jq a
# PreToolUse call in an active session is denied (hook_fail_closed); otherwise the mode applies:
#   fatal    stderr message, exit 1 (Claude Code treats it as a non-blocking error)
#   silent   exit 0
#   empty    print {} and exit 0 (summary writers)
#   continue return with JQ empty (hook tolerates failing jq calls; stdin is left unread)
hook_jq_init() {
  local why="jq not found at \$HOOK_DIR/bin/jq nor on PATH: install jq or reinstall @civitas-cerebrum/achilles, which bundles it."
  JQ="${HOOK_IO_DIR%/lib}/bin/jq"
  [ -x "$JQ" ] || JQ="$(command -v jq || true)"
  [ -n "$JQ" ] && return 0
  [ "$1" = continue ] && return 0
  hook_fail_closed "$why"
  case "$1" in
    fatal)  echo "[${0##*/}] FATAL: $why" >&2; exit 1 ;;
    silent) exit 0 ;;
    empty)  printf '{}\n'; exit 0 ;;
  esac
}

# hook_lib <file>... — source lib/<file>; one that is missing fails the hook (hook_fail_closed,
# then exit 1). hook-io.sh itself cannot be covered: it is what does the covering.
hook_lib() {
  local hook__f
  for hook__f in "$@"; do
    [ -r "$HOOK_IO_DIR/$hook__f" ] && . "$HOOK_IO_DIR/$hook__f" && continue
    hook_fail_closed "lib/$hook__f is missing from the hook install: reinstall @civitas-cerebrum/achilles."
    echo "[${0##*/}] FATAL: lib/$hook__f is missing from the hook install." >&2
    exit 1
  done
}

# hook_fail_closed <reason> — exit 2 with <reason> on stderr when this is a PreToolUse call and the
# protocol is active; otherwise return. The session counts as active when the activation lib is
# unavailable or is the one still loading (HOOK_ACTIVATION_LOADING): an unknown state enforces.
hook_fail_closed() {
  [ -n "${INPUT+x}" ] || INPUT=$(cat)
  hook_is_pre_tool_use "$INPUT" || return 0
  if [ -z "${HOOK_ACTIVATION_LOADING:-}" ] &&
     { declare -F achilles_session_active >/dev/null || . "$HOOK_IO_DIR/achilles-activation.sh" 2>/dev/null; } &&
     declare -F achilles_session_active >/dev/null; then
    achilles_session_active "$INPUT" || return 0
  fi
  echo "[${0##*/}] BLOCKED: this Achilles gate cannot run, so the call is denied while the protocol is active. $1" >&2
  exit 2
}

# hook_is_pre_tool_use <json> — the event field when present; without it, a tool call that has
# no tool_response yet.
hook_is_pre_tool_use() {
  case "$(hook_json_str "$1" .hook_event_name)" in
    PreToolUse) return 0 ;;
    '') [ -n "$(hook_json_str "$1" .tool_name)" ] && [ -z "$(hook_json_str "$1" .tool_response)" ] ;;
    *) return 1 ;;
  esac
}

# hook_json_str <json> <jq-path> — string at <jq-path>, empty when absent. Without JQ, the first
# string value whose key is the path's last segment (escapes kept): enough for the flat ids,
# names and paths the fail-closed and activation checks read.
hook_json_str() {
  if [ -n "${JQ:-}" ]; then
    printf '%s' "$1" | "$JQ" -r "$2 // empty" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$1" | grep -oE "\"${2##*.}\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]|\\\\.)*\"|\\{)" | head -n 1 |
    sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"?//; s/"$//'
}

# hook_read_input — INPUT holds the whole hook payload.
hook_read_input() { INPUT=$(cat); }

# hook_field <jq-path> — e.g. hook_field .tool_input.file_path
hook_field() { hook_json_str "$INPUT" "$1"; }
