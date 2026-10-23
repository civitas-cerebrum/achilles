#!/bin/bash
# lib/protected-paths.sh: one registry of literal entries, matched on normalised paths by both guards.
# Every entry is denied through the guard(s) its tag names; the frozen lists below are spellings
# that must stay protected and near-misses that must stay allowed.
BASH_GUARD="$HOOK_DIR/protected-artifact-bash-guard.sh"
WRITE_GUARD="$HOOK_DIR/hook-authored-state-guard.sh"
. "$HOOK_DIR/lib/hook-io.sh"
hook_lib protected-paths.sh

PP_BASH_PROTECTED='tests/e2e/docs/onboarding-status.json
tests/perf/docs/perf-onboarding-status.json
tests/e2e/docs/journey-map.md
tests/e2e/docs/.phase4-cycle-state.json
tests/e2e/docs/coverage-expansion-state.json
tests/e2e/docs/.workflow-approvers.json
tests/e2e/docs/adversarial-findings.md
tests/e2e/docs/.ledger-integrity.json
tests/e2e/docs/flake-quarantine.md
.workflow-approvers.json
.ledger-integrity.json
.claude/achilles/sessions/s1.active
.claude/hooks/onboarding-ledger-gate.sh
.claude/settings.json
.claude/settings.local.json
/home/u/.claude/settings.local.json
/home/u/.CLAUDE/Settings.json
.claude//hooks/a.sh
.claude/./hooks/a.sh
.claude/x/../hooks/a.sh
~/.claude/hooks/a.sh'
PP_BASH_NEAR_MISS='tests/e2e/docs/onboarding-statusXjson
tests/e2e/docs/journey-map.txt
tests/e2e/docs/phase4-cycle-state.json
tests/e2e/docs/coverage-expansion-state.yaml
tests/e2e/docs/workflow-approvers.json
tests/e2e/docs/adversarial-findings.txt
tests/e2e/docs/ledger-integrity.json
tests/e2e/docs/flake-quarantine.txt
.claude/achille
.claude/hook
.claude/settingsXjson
.claude/settings.local.yaml
.claude/hooks/../skills/a.md
/tmp/scratch.json'
PP_WRITE_PROTECTED='tests/e2e/docs/.workflow-approvers.json
tests/perf/docs/.workflow-approvers.json
tests/e2e/docs/.ledger-integrity.json
tests/perf/docs/.ledger-integrity.json
/abs/proj/tests/e2e/docs/.workflow-approvers.json
/abs/proj/tests/perf/docs/.ledger-integrity.json
tests/e2e/docs//.workflow-approvers.json
tests/E2E/docs/.Workflow-Approvers.json
tests/e2e/x/../docs/.ledger-integrity.json
tests/e2e/./docs/.ledger-integrity.json'
PP_WRITE_NEAR_MISS='tests/e2e/docs/.workflow-approvers.json.bak
tests/e2e/docs/workflow-approvers.json
tests/e2e/docs/.ledger-integrity.jsonl
tests/unit/docs/.workflow-approvers.json
tests/e2e/other/.ledger-integrity.json
tests/e2e/docs/../.workflow-approvers.json
docs/.workflow-approvers.json
tests/e2e/docs/onboarding-status.json'

bash_cmd() { "$JQ" -n --arg c "echo x > $1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
write_call() { "$JQ" -n --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, content:"{}", old_string:"a", new_string:"b"}}'; }

section "protected-paths: every registry entry is denied through the guards its tag names"
for e in "${PROTECTED_PATHS[@]}"; do
  name="${e%|*}"
  case "${e##*|}" in
    bash|both) assert_deny "$BASH_GUARD" "$(bash_cmd "/abs/proj/$name")" "Bash write into $name" "protected" ;;
  esac
  case "${e##*|}" in
    write|both)
      for dir in "${LEDGER_ONBOARDING_REL%/*}" "${LEDGER_PERF_REL%/*}"; do
        assert_deny "$WRITE_GUARD" "$(write_call Write "$dir/$name")" "Write $dir/$name" "hook-authored state"
      done ;;
  esac
done

section "protected-paths: the Bash guard denies the frozen protected spellings"
while IFS= read -r p; do
  assert_deny "$BASH_GUARD" "$(bash_cmd "$p")" "redirect into $p" "protected"
done <<< "$PP_BASH_PROTECTED"

section "protected-paths: the Bash guard allows the near-misses"
while IFS= read -r p; do
  assert_allow "$BASH_GUARD" "$(bash_cmd "$p")" "redirect into $p"
done <<< "$PP_BASH_NEAR_MISS"

section "protected-paths: the Write and Edit guards deny the frozen protected spellings"
while IFS= read -r p; do
  assert_deny "$WRITE_GUARD" "$(write_call Write "$p")" "Write $p" "hook-authored state"
  assert_deny "$WRITE_GUARD" "$(write_call Edit "$p")" "Edit $p" "hook-authored state"
done <<< "$PP_WRITE_PROTECTED"

section "protected-paths: the Write and Edit guards allow the near-misses"
while IFS= read -r p; do
  assert_allow "$WRITE_GUARD" "$(write_call Write "$p")" "Write $p"
  assert_allow "$WRITE_GUARD" "$(write_call Edit "$p")" "Edit $p"
done <<< "$PP_WRITE_NEAR_MISS"

section "protected-paths: entries are literal (no regex, no glob)"
pp_literal() {  # pp_literal <matcher> <path>
  ( PROTECTED_PATHS=('a+b.json|both' '*.md|bash' 'x[1].json|bash'); "$1" "$2" >/dev/null && echo protected || echo allowed )
}
assert_eq "$(pp_literal protected_bash_match p/a+b.json)" protected "Bash: 'a+b.json' protects p/a+b.json"
assert_eq "$(pp_literal protected_bash_match p/aab.json)" allowed "Bash: 'a+b.json' is not a regex"
assert_eq "$(pp_literal protected_bash_match 'p/*.md')" protected "Bash: '*.md' protects only p/*.md"
assert_eq "$(pp_literal protected_bash_match p/notes.md)" allowed "Bash: '*.md' is not a glob"
assert_eq "$(pp_literal protected_bash_match p/x1.json)" allowed "Bash: 'x[1].json' is not a bracket expression"
assert_eq "$(pp_literal protected_write_match tests/e2e/docs/a+b.json)" protected "Write: 'a+b.json' protects docs/a+b.json"
assert_eq "$(pp_literal protected_write_match tests/e2e/docs/aab.json)" allowed "Write: 'a+b.json' is not a regex"
