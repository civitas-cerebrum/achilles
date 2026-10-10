#!/bin/bash
# hook-io.sh — jq bootstrap, lib loading and hook-input access shared by every Achilles hook.
# Builtins only: the factory gates load this with PATH emptied.
case "${BASH_SOURCE[0]}" in */*) HOOK_IO_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)";; *) HOOK_IO_DIR="$PWD";; esac

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

# hook_json_str <json> <jq-path> — string at <jq-path>, empty when absent. Without JQ, an awk
# scanner walks the document (strings and escapes respected) and prints the value whose key path
# is <jq-path>, escapes kept, `{` or `[` for an object or array: enough for the ids, names and
# paths the fail-closed and activation checks read, and not fooled by the same key nested deeper
# or inside a string value. A JQ that cannot run (exit 126 and up: not executable, killed, as
# macOS does to an unsigned binary) falls to the scanner too: read as "no session_id", an
# unrunnable jq would activate the protocol in every session.
hook_json_str() {
  if [ -n "${JQ:-}" ]; then
    local hook__out hook__rc
    hook__out=$(printf '%s' "$1" | "$JQ" -r "$2 // empty" 2>/dev/null); hook__rc=$?
    if [ "$hook__rc" -lt 126 ]; then
      [ -z "$hook__out" ] || printf '%s\n' "$hook__out"
      return 0
    fi
  fi
  printf '%s' "$1" | LC_ALL=C awk -v path="${2#.}" '
    BEGIN { n = split(path, want, "."); RS = "\001" }
    function hit(k) { if (d != n) return 0; for (k = 1; k <= n; k++) if (key[k] != want[k]) return 0; return 1 }
    { s = $0; L = length(s); i = 1; d = 0; iskey = 0
      while (i <= L) {
        c = substr(s, i, 1)
        if (c == "\"") {
          v = ""; i++
          while (i <= L) {
            c = substr(s, i, 1)
            if (c == "\\") { v = v c substr(s, i + 1, 1); i += 2; continue }
            if (c == "\"") break
            v = v c; i++
          }
          if (iskey) { key[d] = v; iskey = 0 } else if (hit()) { print v; exit }
        } else if (c == "{" || c == "[") {
          if (hit()) { print c; exit }
          d++; ctx[d] = c; iskey = (c == "{"); key[d] = ""
        } else if (c == "}" || c == "]") d--
        else if (c == ",") iskey = (ctx[d] == "{")
        i++
      } }'
}

# hook_read_input — INPUT holds the whole hook payload.
hook_read_input() { INPUT=$(cat); }

# hook_field <jq-path> — e.g. hook_field .tool_input.file_path
hook_field() { hook_json_str "$INPUT" "$1"; }
