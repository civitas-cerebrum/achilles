#!/bin/bash
# The shipped QA mandate in the vendored kernel: scopes the methodology depends on.
KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
MANDATE="$HOOK_DIR/data/achilles-qa.kernel-mandate.json"
QS_TMP=$(mktemp -d); QP="$QS_TMP/proj"
mkdir -p "$QP/.claude" "$QP/tests/e2e/docs" "$QP/src"
cp "$MANDATE" "$QP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_MANIFEST="$QP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_STATE_DIR="$QS_TMP/state"
qs_main() { payload "$@" cwd="$QP"; }
qs_sub()  { payload "$@" cwd="$QP" | "$JQ" -c '. + {agent_id: ("sub-" + .agent_type)}'; }

section "qa-mandate: composers grow the page repository; other authors do not"
assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=test-composer file_path="$QP/tests/e2e/page-repository.json" content='{"pages":[]}')" \
  "test-composer Write tests/e2e/page-repository.json → ALLOW (test-composer/SKILL.md stage 1 adds selectors)"
assert_allow "$KERNEL" "$(qs_sub tool_name=Edit agent_type=test-composer file_path="$QP/tests/e2e/page-repository.json" old_string='[]' new_string='[{}]')" \
  "test-composer Edit the page repository → ALLOW"
for P in page-repository.backup.json other/page-repository.v2.json fixtures/page-repository.json foo/page-repository.json; do
  assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=test-composer file_path="$QP/tests/e2e/$P" content='{}')" \
    "test-composer Write tests/e2e/$P → DENY (D-1 grants the one exact path)" "explicitly denied write"
done
assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=stage2 file_path="$QP/tests/e2e/page-repository.json" content='{}')" \
  "stage2 Write the page repository → DENY (it returns proposed entries instead)" "outside the role's write scope"
for R in probe cleanup fd; do
  assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=$R file_path="$QP/tests/e2e/page-repository.json" content='{}')" \
    "$R Write the page repository → DENY (only scaffolder and composers author selectors)" "explicitly denied write"
done
assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=probe file_path="$QP/tests/e2e/fixtures/page-repository.v2.json" content='{}')" \
  "probe Write a nested, suffixed page repository → DENY (glob, not path literal)" "explicitly denied write"
assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=test-composer file_path="$QP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "test-composer Write the status ledger → still DENY" "explicitly denied write"

rm -rf "$QS_TMP"
unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR
