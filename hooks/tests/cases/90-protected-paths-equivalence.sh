#!/bin/bash
# lib/protected-paths.sh renders the Bash guard's regex and the Write guard's path test from one
# registry. Both lists below are the hand-kept forms the registry replaced; every path they
# protected stays protected, and the near-misses next to each stay allowed.
BASH_GUARD="$HOOK_DIR/protected-artifact-bash-guard.sh"
WRITE_GUARD="$HOOK_DIR/hook-authored-state-guard.sh"
. "$HOOK_DIR/lib/protected-paths.sh"

OLD_BASH_RE='onboarding-status\.json|perf-onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|flake-quarantine\.md|\.claude/achilles|\.claude/hooks|\.claude/settings(\.local)?\.json'

old_write_match() {
  case "/${1#/}" in
    */tests/e2e/docs/.workflow-approvers.json | */tests/perf/docs/.workflow-approvers.json | \
    */tests/e2e/docs/.ledger-integrity.json | */tests/perf/docs/.ledger-integrity.json) return 0 ;;
  esac
  return 1
}

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
/home/u/.claude/settings.local.json'
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
/tmp/scratch.json'
PP_WRITE_PROTECTED='tests/e2e/docs/.workflow-approvers.json
tests/perf/docs/.workflow-approvers.json
tests/e2e/docs/.ledger-integrity.json
tests/perf/docs/.ledger-integrity.json
/abs/proj/tests/e2e/docs/.workflow-approvers.json
/abs/proj/tests/perf/docs/.ledger-integrity.json'
PP_WRITE_NEAR_MISS='tests/e2e/docs/.workflow-approvers.json.bak
tests/e2e/docs/workflow-approvers.json
tests/e2e/docs/.ledger-integrity.jsonl
tests/unit/docs/.workflow-approvers.json
tests/e2e/other/.ledger-integrity.json
docs/.workflow-approvers.json
tests/e2e/docs/onboarding-status.json'

bash_cmd() { "$JQ" -n --arg c "echo x > $1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
write_call() { "$JQ" -n --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, content:"{}", old_string:"a", new_string:"b"}}'; }
verdict_of() { if "$1" "$2"; then echo protected; else echo allowed; fi; }

section "protected-paths: the Bash guard denies each path the hand-kept regex protected"
while IFS= read -r p; do
  assert_eq "$(echo "$p" | grep -cE "$OLD_BASH_RE")" 1 "fixture: old regex protects '$p'"
  assert_deny "$BASH_GUARD" "$(bash_cmd "$p")" "redirect into $p" "protected"
done <<< "$PP_BASH_PROTECTED"

section "protected-paths: the Bash guard allows the near-misses"
while IFS= read -r p; do
  assert_eq "$(echo "$p" | grep -cE "$OLD_BASH_RE")" 0 "fixture: old regex ignores '$p'"
  assert_allow "$BASH_GUARD" "$(bash_cmd "$p")" "redirect into $p"
done <<< "$PP_BASH_NEAR_MISS"

section "protected-paths: the rendered regex and the old one agree on every path"
NEW_BASH_RE=$(protected_bash_regex)
while IFS= read -r p; do
  assert_eq "$(echo "$p" | grep -cE "$NEW_BASH_RE")" "$(echo "$p" | grep -cE "$OLD_BASH_RE")" "regex verdict for '$p'"
done <<< "$PP_BASH_PROTECTED
$PP_BASH_NEAR_MISS"

section "protected-paths: the Write and Edit guards deny each path the hand-kept case protected"
while IFS= read -r p; do
  assert_deny "$WRITE_GUARD" "$(write_call Write "$p")" "Write $p" "hook-authored state"
  assert_deny "$WRITE_GUARD" "$(write_call Edit "$p")" "Edit $p" "hook-authored state"
done <<< "$PP_WRITE_PROTECTED"

section "protected-paths: the Write and Edit guards allow the near-misses"
while IFS= read -r p; do
  assert_allow "$WRITE_GUARD" "$(write_call Write "$p")" "Write $p"
  assert_allow "$WRITE_GUARD" "$(write_call Edit "$p")" "Edit $p"
done <<< "$PP_WRITE_NEAR_MISS"

section "protected-paths: protected_write_match and the old case agree on every path"
while IFS= read -r p; do
  assert_eq "$(verdict_of protected_write_match "$p")" "$(verdict_of old_write_match "$p")" "write verdict for '$p'"
done <<< "$PP_WRITE_PROTECTED
$PP_WRITE_NEAR_MISS"
