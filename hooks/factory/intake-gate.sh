#!/bin/bash
# intake-gate.sh — denies a new spec whose tests do not trace to a written
#                  scenario, and new files in frozen directories
#                  (rule specs.shape).
#
# Hook    : PreToolUse:Write|Edit|MultiEdit
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (reads the rule file and the scenario documents)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
#
# Rule
# ----
# 1. Frozen directories: a write that CREATES a file under a `frozenDirs` entry is denied (editing an
#    existing file there is allowed).
# 2. Intake: a write that CREATES a spec (*.spec.* / *.test.*) under a `scope` glob, outside `exclude`,
#    is judged title by title — test('…'), test("…"), test(`…`) and test.skip|fixme|only|fail|slow(…);
#    commented-out lines are ignored. Every title must match `titleIdPattern`, the id must head a block
#    in one of `scenarioDocs` (a Markdown heading "<#…> <ID> …"), and — when `lint` is set — the lint
#    (`<lint…> --id <ID> <doc…>`, run from the project root) must exit 0; its "[specs.shape] …" lines
#    (else its first line) are quoted in the deny.
# Existing specs are never judged: the gate is an intake check, not a retrofit.
#
# Why
# ---
# A spec written before its scenario is the agent's idea of the feature, not the requirement. Forcing
# the scenario block first keeps one written source for what is tested, why, and how it is verified.
#
# Known limit: titles are found with a regex over comment-masked text; a title built at runtime
# (template expressions, a helper that calls test()) is not seen. The project's verify step is the detector.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#specs.shape

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=specs.shape
rule_enabled "$ID"
[ -n "$FILE_PATH" ] || exit 0
[ -e "$FILE_PATH" ] && exit 0   # only new files are judged
REL="$(rel_path "$FILE_PATH")"

while IFS= read -r d; do
  [ -z "$d" ] && continue; d="${d%/}"
  case "$REL" in "$d"/*) emit_deny "$ID" "$(tool_verb) $REL creates a new file under the frozen $d/ directory." \
    "Put the new file under a directory that is not frozen (frozenDirs in $(rules_rel)); editing an existing file there is allowed, and lifting a freeze is an owner decision.";; esac
done < <(rule_array "$ID" frozenDirs)

[ -n "$CONTENT" ] || exit 0
case "$REL" in *.spec.*|*.test.*) ;; *) exit 0;; esac
in_scope "$REL" "$ID" || exit 0
in_scope "$REL" "$ID" exclude && exit 0
PATTERN="$(rule_field "$ID" titleIdPattern)"
[ -n "$PATTERN" ] || emit_allow_warn "$ID.titleIdPattern missing in $(rules_rel) — intake gate skipped"
DOCS=(); while IFS= read -r d; do [ -n "$d" ] && DOCS+=("$FACTORY_ROOT/$d"); done < <(rule_array "$ID" scenarioDocs)
LINT=(); while IFS= read -r a; do [ -n "$a" ] && LINT+=("$a"); done < <(rule_array "$ID" lint)
LINT_OK=  # decided at the first id: 1 = run the lint, 0 = no lint configured or it cannot run (warned once)
lint_ready() {
  [ -n "$LINT_OK" ] && return 0
  LINT_OK=0
  [ ${#LINT[@]} -gt 0 ] || return 0
  if ! command -v "${LINT[0]}" >/dev/null 2>&1 && [ ! -x "$FACTORY_ROOT/${LINT[0]}" ]; then
    echo "[factory] ${LINT[0]} not found — $ID scenario lint skipped; the project's verify step is the detector" >&2; return 0
  fi
  local a
  for a in "${LINT[@]:1}"; do
    case "$a" in -*) ;; *) [ -e "$FACTORY_ROOT/$a" ] || { echo "[factory] $a missing — $ID scenario lint skipped; the project's verify step is the detector" >&2; return 0; }; break;; esac
  done
  LINT_OK=1
}

# One line per title: "<id>\x1f<title>" (a non-whitespace separator so an empty id survives `read`; the id is
# empty when the title does not match the pattern).
ROWS="$(printf '%s\n' "$CONTENT" | mask_comments | "$JQ" -Rsr --arg re "$PATTERN" '
  [ scan("(?<![\\w.$])test(?:\\.(?:skip|fixme|only|fail|slow))?\\(\\s*(?:\u0027([^\u0027\\n]*)\u0027|\"([^\"\\n]*)\"|`([^`]*)`)") | map(select(. != null))[0] ]
  | .[] | . as $t | ((try (capture("(?<m>" + $re + ")").m) catch null) // "") as $m
  | "\($m | sub(" — $"; "") | sub(" +$"; ""))\u001f\($t | gsub("[\u001f\n]"; " "))"' 2>/dev/null)" \
  || emit_allow_warn "could not parse test titles in $REL — intake gate skipped; the project's verify step is the detector"

DENY_WHAT() { emit_deny "$ID" "New spec $REL has a test without a written scenario ($1)."; }
has_block() {  # has_block <id> — a Markdown heading "#… <id>" (followed by a space or the end of the line) in a scenario doc
  local id="$1" doc line rest
  for doc in ${DOCS[@]+"${DOCS[@]}"}; do
    [ -f "$doc" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "#"*) ;; *) continue;; esac
      rest="${line#"${line%%[!#]*}"}"; rest="${rest# }"
      case "$rest" in "$id"|"$id "*) return 0;; esac
    done < "$doc"
  done
  return 1
}
while IFS=$'\x1f' read -r id title; do
  [ -z "$id$title" ] && continue
  [ -n "$id" ] || DENY_WHAT "$title"
  has_block "$id" || DENY_WHAT "$title — no scenario block headed $id in ${DOCS[*]#"$FACTORY_ROOT"/}"
  lint_ready; [ "$LINT_OK" = 1 ] || continue
  LINT_OUT="$(cd "$FACTORY_ROOT" && "${LINT[@]}" --id "$id" ${DOCS[@]+"${DOCS[@]}"} 2>&1)" || {
    WHY="$(printf '%s\n' "$LINT_OUT" | grep '^\[specs\.shape\] ' | sed 's/^\[specs\.shape\] //' | head -3 | paste -sd ';' -)"
    DENY_WHAT "$title — ${WHY:-$(printf '%s\n' "$LINT_OUT" | head -1)}"; }   # no [specs.shape] line (a crash) → the first line
done <<< "$ROWS"
exit 0
