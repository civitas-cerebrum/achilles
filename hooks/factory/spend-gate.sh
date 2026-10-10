#!/bin/bash
# spend-gate.sh — denies a test run that would execute a spend-incurring
#                 spec (real orders, paid API calls) without the project's
#                 per-command opt-in (rule spend.opt-in).
#
# Hook    : PreToolUse:Bash (commands naming playwright, the project wrapper or a spend script)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (reads the rule file and the spend list <list> = { "specs": [<project-relative path>, …] })
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
#
# Rule
# ----
# Per shell segment (quote-aware; hooks/lib/spend-classify.cjs), unless THAT segment opts in —
# `<optInEnv>=1` as a leading assignment of `playwright test` / `npm run <spendScript>`, or `<optInFlag>`
# on the `<wrapper>` command (a project runner that excludes the list by default) — deny when:
#   * a file argument (":line[:col]" stripped, ".." and the project root resolved) is part of a listed
#     path or contains one (basename, stem, directory, absolute path; Playwright file filters are path
#     regexes);
#   * `playwright test` (incl. --list) has no file argument and no --project, or a --project from
#     `spendProjects`;
#   * `npm run <spendScript>` (an unfiltered run of a spend project).
# One level of `bash|sh|zsh -c '…'` / `eval '…'` is classified too; a spec or project argument that is a
# shell expansion ($SPEC) cannot be judged → deny, asking for a literal path.
#
# Why
# ---
# Some specs cost money or consume shared quota on every run. The opt-in makes each such run an
# explicit, per-command decision recorded in the command itself; an opt-in exported in an earlier
# segment or session does not count.
#
# Known limit: Bash classification is best effort — aliases, functions, scripts that call the runner
# and deeper nesting are not seen. The spend list is also enforced by the project's wrapper (which
# excludes the list by default) and by the project's verify step.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#spend.opt-in

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=spend.opt-in
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
WRAPPER="$(rule_field "$ID" wrapper)"; WRAPPER="${WRAPPER##*/}"
TRIGGER=0
[[ "$COMMAND" == *playwright* ]] && TRIGGER=1
[ -n "$WRAPPER" ] && [[ "$COMMAND" == *"$WRAPPER"* ]] && TRIGGER=1
if [ $TRIGGER = 0 ] && [[ "$COMMAND" == *npm* ]]; then
  while IFS= read -r s; do [ -n "$s" ] && [[ "$COMMAND" == *"$s"* ]] && TRIGGER=1; done < <(rule_array "$ID" spendScripts)
fi
[ $TRIGGER = 1 ] || exit 0
LIST_REL="$(rule_field "$ID" list)"; FLAG="$(rule_field "$ID" optInFlag)"; ENVN="$(rule_field "$ID" optInEnv)"
[ -n "$LIST_REL" ] && [ -n "$FLAG" ] && [ -n "$ENVN" ] || emit_allow_warn "$ID list/optInFlag/optInEnv missing in $(rules_rel) — spend gate skipped"
[ -f "$FACTORY_ROOT/$LIST_REL" ] || emit_allow_warn "$LIST_REL missing — spend gate skipped; the project's verify step is the detector"
NODE="${FACTORY_NODE-$(command -v node || true)}"
[ -n "$NODE" ] && [ -x "$NODE" ] || emit_allow_warn "node not found — spend gate skipped; the project wrapper still excludes the listed specs"
WHAT="$("$NODE" "$_FACTORY_LIB/spend-classify.cjs" "$COMMAND" "$FACTORY_ROOT" "${CWD:-$FACTORY_ROOT}" "$RULES" 2>/dev/null)" \
  || emit_allow_warn "could not classify the command — spend gate skipped"
[ -n "$WHAT" ] || exit 0
emit_deny "$ID" "$WHAT"
