#!/bin/bash
# factory-common.sh — shared spine of the factory gates (hooks/factory/*.sh).
#
# Sourced by every factory gate. Resolves the project root and the rule file,
# finds jq, reads the hook payload once, and provides the rule accessors, path
# helpers and the three-line deny emitter.
#
# Config contract
#   FACTORY_ROOT — the project root: $CLAUDE_PROJECT_DIR, else the current directory.
#   RULES        — the rule file: $FACTORY_RULES (absolute, or relative to the root),
#                  else <root>/achilles-factory-rules.json — a COMMITTED file at the project root
#                  (.achilles/ is gitignored by onboarding, so a rule file there would be absent in
#                  every other clone and the gates silently off).
#   JQ           — $FACTORY_JQ (tests), else the jq bundled next to the hooks, else jq on PATH.
#
# Outcome contract (see references/factory-gates.md#message-contract)
#   * no rule file, or the gate's rule id absent → silent allow: the project has not opted in;
#   * jq missing, rule file not a JSON object, hook payload not a JSON object, a rule field the
#     gate needs is missing, a helper cannot run → allow-with-warning: one "[factory] …" line on
#     stderr, exit 0. Achilles ships no verify-step guard: the detector is the PROJECT's verify
#     step (schema validation of the rule file, plus whatever content checks it mirrors);
#   * a violation → a PreToolUse deny whose reason is exactly three lines:
#       [<rule-id>] <what happened>
#       → Do: <the sanctioned alternative>
#       → Why/how: <doc#anchor>
# A gate never writes a file.
#
# Pure bash where it matters: with PATH emptied (no cat, dirname or jq) a gate still loads and
# allows with a warning.

set -uo pipefail
_FACTORY_LIB="${BASH_SOURCE[0]%/*}"
FACTORY_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
FACTORY_ROOT="${FACTORY_ROOT%/}"
RULES="${FACTORY_RULES:-achilles-factory-rules.json}"
case "$RULES" in /*) ;; *) RULES="$FACTORY_ROOT/$RULES";; esac
if [ -n "${FACTORY_JQ:-}" ]; then JQ="$FACTORY_JQ"; else JQ="$_FACTORY_LIB/../bin/jq"; fi
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
IFS= read -r -d '' INPUT || true   # the whole payload, without an external `cat`

emit_allow_warn() { echo "[factory] $1" >&2; exit 0; }   # allow-with-warning: never brick the session

rules_rel() { case "$RULES" in "$FACTORY_ROOT"/*) printf '%s' "${RULES#"$FACTORY_ROOT"/}";; *) printf '%s' "$RULES";; esac; }

factory_guard_ready() {
  [ -f "$RULES" ] || exit 0   # no rule file = the project has not opted in
  [ -n "$JQ" ] || emit_allow_warn "jq not found — gate skipped; the project's verify step is the detector"
  "$JQ" -e '(type == "object") and ((.rules | type) == "object")' "$RULES" >/dev/null 2>&1 \
    || emit_allow_warn "$(rules_rel) is not a JSON object with a \"rules\" object — gate skipped; the project's verify step is the detector"
}

rule_enabled() {  # rule_enabled <rule-id> — exit 0 (silent allow) when the rule file has no object for this rule id
  "$JQ" -e --arg id "$1" '(.rules[$id] | type) == "object"' "$RULES" >/dev/null 2>&1 || exit 0
}

normalize_path() {  # normalize_path <abs path> — resolve ".", ".." and "//" lexically (macOS has no realpath -m)
  local p="$1" seg out=() IFS=/ noglob=0
  case "$-" in *f*) noglob=1;; esac
  set -f   # a segment like "*" or "[a]" must not be glob-expanded (bash 3.2 has no `local -`, so restore by hand)
  for seg in $p; do
    case "$seg" in ''|.) ;; ..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]';; *) out+=("$seg");; esac
  done
  [ "$noglob" = 1 ] || set +f
  printf '/%s' "${out[*]-}"
}

factory_read_input() {
  printf '%s' "$INPUT" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || emit_allow_warn "hook input is not a JSON object — gate skipped; the project's verify step is the detector"
  TOOL_NAME="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty')"
  FILE_PATH="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty')"
  # Write content, Edit new_string and every MultiEdit edits[].new_string, joined by newlines.
  CONTENT="$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(type == "string")) | join("\n")')"
  COMMAND="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty')"
  CWD="$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty')"
  # A relative file_path resolves against the call's cwd (else the project root), and ".." segments are resolved
  # before any scope or existence decision, so "tests/e2e/north/../api/x.ts" is judged as tests/e2e/api/x.ts.
  # Symlinks are not followed (lexical only); a gate that must see through them resolves the parent directory itself.
  case "$FILE_PATH" in ''|/*) ;; *) FILE_PATH="${CWD:-$FACTORY_ROOT}/$FILE_PATH";; esac
  [ -n "$FILE_PATH" ] && FILE_PATH="$(normalize_path "$FILE_PATH")"
  return 0
}

rule_field() { "$JQ" -r --arg id "$1" --arg p "$2" '.rules[$id] | getpath($p | split(".")) // empty | if type == "array" then .[] else . end' "$RULES"; }
rule_array() { "$JQ" -r --arg id "$1" --arg f "$2" '.rules[$id][$f][]?' "$RULES"; }
tool_verb() { case "${TOOL_NAME:-}" in Edit|MultiEdit) printf 'Edit of';; *) printf 'Write to';; esac; }
rel_path() { local r; r="$(normalize_path "$FACTORY_ROOT")"; case "$1" in "$r"/*) printf '%s' "${1#"$r"/}";; *) printf '%s' "$1";; esac; }

in_scope() {  # in_scope <relpath> <rule-id> [field=scope] — bash glob match per entry; "dir/**" also matches dir itself
  local rel="$1" id="$2" f="${3:-scope}" g
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    case "$rel" in ${g%/\*\*}/*|${g%/\*\*}) return 0;; esac
  done < <(rule_array "$id" "$f")
  return 1
}

# mask_comments — best-effort comment masking for a write gate (the project's verify step is the detector):
#   * each /* … */ on one line is removed non-greedily first (code between or after two comments survives);
#   * a line whose first non-blank characters are "*", "/*" or "/**" (JSDoc body, unclosed opener) is blanked;
#   * "// …" to the end of the line is removed.
# Residual gaps: a block-comment body line that does not start with "*" is still checked; "//" or "/*" inside a
# string literal (a URL) masks the rest of that line; a code line starting with "*" (a multiplication
# continuation) is skipped.
mask_comments() { sed -E 's#/\*([^*]|\*+[^*/])*\*+/##g; s#^[[:space:]]*(/\*|\*).*$##; s#//.*$##'; }

emit_deny() {  # emit_deny <rule-id> <what> [<action>] — the action defaults to the rule's "action" field
  local id="$1" what="$2" action="${3:-}" doc
  [ -n "$action" ] || action="$(rule_field "$id" action)"
  doc="$(rule_field "$id" doc)"
  [ -n "$doc" ] || doc="skills/achilles-protocol/references/factory-gates.md#$id"
  local msg; msg="$(printf '[%s] %s\n→ Do: %s\n→ Why/how: %s' "$id" "$what" "$action" "$doc")"
  "$JQ" -n --arg r "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
