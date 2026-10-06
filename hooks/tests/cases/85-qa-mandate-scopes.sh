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

section "secrets-sweep-phase7"
qs_disp() { # <description> <role>
  qs_main tool_name=Agent description="$1" prompt="<<kernel-mandate-role: $2#k7m2p9>>
Phase 7." | "$JQ" -c --arg t "$2" '.tool_input.subagent_type = $t'
}
assert_allow "$KERNEL" "$(qs_disp 'scaffolder-phase7: wire .env for the key list' scaffolder)" "orchestrator dispatches scaffolder-phase7 + tag → ALLOW"
assert_allow "$KERNEL" "$(qs_disp 'secrets-sweep-phase7: rewrite literals to process.env' secrets-sweep)" "orchestrator dispatches secrets-sweep-phase7 + tag → ALLOW"
for F in .env .env.example .gitignore; do
  assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=scaffolder file_path="$QP/$F" content='X=1')" "scaffolder Write $F → ALLOW"
done
assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=scaffolder file_path="$QP/playwright.contracts.config.ts" content='export default {};')" "scaffolder Write playwright.contracts.config.ts → ALLOW (glob)"
assert_allow "$KERNEL" "$(qs_main tool_name=Read file_path="$QP/playwright.contracts.config.ts")" "orchestrator Read playwright.contracts.config.ts → ALLOW"
assert_deny "$KERNEL" "$(qs_main tool_name=Write file_path="$QP/playwright.contracts.config.ts" content='export default {};')" \
  "orchestrator Write playwright.contracts.config.ts → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=test-composer file_path="$QP/playwright.contracts.config.ts" content='export default {};')" \
  "test-composer Write playwright.contracts.config.ts → DENY" "outside the role's write scope"
assert_allow "$KERNEL" "$(qs_sub tool_name=Read agent_type=scaffolder file_path="$QP/.env")" "scaffolder Read .env → ALLOW (appends without duplicating keys)"
assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=scaffolder file_path="$QP/playwright.config.ts" content='import "dotenv/config"; import { defineConfig } from "@playwright/test"; export default defineConfig({});')" \
  "scaffolder config importing dotenv → ALLOW (no import list; bounded by having no shell)"
assert_deny "$KERNEL" "$(qs_sub tool_name=Bash agent_type=scaffolder command='npx playwright test')" \
  "scaffolder Bash → DENY" "may not use the 'Bash' tool"
assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=secrets-sweep file_path="$QP/tests/e2e/fixtures/users.ts" content='import { test } from "@playwright/test"; export const u = process.env.TEST_USER_EMAIL;')" \
  "secrets-sweep Write a fixture with process.env → ALLOW"
assert_allow "$KERNEL" "$(qs_sub tool_name=Write agent_type=secrets-sweep file_path="$QP/tests/e2e/page-repository.json" content='{"pages":[]}')" \
  "secrets-sweep Write the page repository → ALLOW (it holds URLs)"
assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=secrets-sweep file_path="$QP/tests/e2e/x.spec.ts" content='import fs from "fs-extra";')" \
  "secrets-sweep importing an undeclared package → DENY" "not in this role's declared import list"
for F in .env .env.example playwright.config.ts; do
  assert_deny "$KERNEL" "$(qs_sub tool_name=Write agent_type=secrets-sweep file_path="$QP/$F" content='X=1')" \
    "secrets-sweep Write $F → DENY" "outside the role's write scope"
done
assert_deny "$KERNEL" "$(qs_sub tool_name=Read agent_type=secrets-sweep file_path="$QP/.env")" \
  "secrets-sweep Read .env → DENY" "outside the role's read scope"
assert_deny "$KERNEL" "$(qs_sub tool_name=Bash agent_type=secrets-sweep command='npx playwright test')" \
  "secrets-sweep Bash → DENY (the orchestrator re-runs the suite)" "may not use the 'Bash' tool"
assert_deny "$KERNEL" "$(qs_sub tool_name=Read agent_type=test-composer file_path="$QP/.env")" \
  "test-composer Read .env → still DENY" "outside the role's read scope"

section "qa-mandate: grouped dispatch binds the composer and probe roles"
assert_allow "$KERNEL" "$(qs_disp 'test-composer-group-p2-auth: j-login, j-signup' test-composer)" "test-composer-group-<id>: + tag → ALLOW"
assert_allow "$KERNEL" "$(qs_disp 'test-composer-p3batch-p2-misc: j-logout, j-role' test-composer)" "test-composer-p3batch-<id>: + tag → ALLOW"
assert_allow "$KERNEL" "$(qs_disp 'probe-group-p4-auth: j-login, j-signup' probe)" "probe-group-<id>: + tag → ALLOW"
assert_deny  "$KERNEL" "$(qs_disp '[group] test-composer-j-login,test-composer-j-signup:' test-composer)" "legacy leading [group] names no role → DENY" ""

rm -rf "$QS_TMP"
unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR
