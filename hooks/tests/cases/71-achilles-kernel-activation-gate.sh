#!/bin/bash
# Tests for achilles-kernel-activation-gate.sh — the REGISTERED entry point
# to the kernel mandate kernel — together with the postinstall wiring that
# puts it there and the QA mandate it consults.
#
# Contract under test:
#   - postinstall registers the WRAPPER on PreToolUse:.* and no longer
#     registers the raw kernel; the kernel is copied beside the wrapper as
#     a companion (the wrapper execs it) and a stale direct registration
#     is pruned.
#   - hooks/data/achilles-qa.kernel-mandate.json is a valid manifest,
#     derived from hooks/data/achilles-qa.workflow.json, and LOADS in the
#     vendored kernel with the intended boundaries (no role reads src/**
#     or .env; approvers have no shell; the main session is `orchestrator`;
#     the runner/resolution configs are the write-only scaffolder's, not
#     the orchestrator's; composers may import exactly the test framework).
#   - every dispatch shape the skills teach — `<role>-<slug>: …` with the
#     `<<kernel-mandate-role: ROLE#nonce>>` tag as the brief's first line —
#     is ALLOWED, the pre-kernel `composer-*` shape is DENIED, and the skill
#     files still carry those literals (drift pin).
#   - the wrapper is dormant without an achilles session marker and relays
#     the kernel's verdict with one; KERNEL_MANDATE=0 still bypasses; a
#     missing kernel script is a silent allow.
#   - postinstall stages the manifest into <project>/.claude/ only when
#     none exists there, never overwrites, and writes nowhere else.

H="$HOOK_DIR/achilles-kernel-activation-gate.sh"
KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
POSTINSTALL="$REPO_ROOT/scripts/postinstall.js"
MANDATE="$HOOK_DIR/data/achilles-qa.kernel-mandate.json"
WORKFLOW="$HOOK_DIR/data/achilles-qa.workflow.json"

# ---------------------------------------------------------------------------
section "kernel wiring: postinstall registers the wrapper, not the raw kernel"
# ---------------------------------------------------------------------------
# HOOK_MANIFEST body only — comments and the companion / superseded lists
# below it must not count as registrations.
MANIFEST_BODY=$(awk '/const HOOK_MANIFEST = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL" | grep -vE '^\s*//')
assert_eq "$(printf '%s' "$MANIFEST_BODY" | grep -cE "file: 'achilles-kernel-activation-gate\.sh',\s+event: 'PreToolUse',\s+matcher: '\.\*'")" "1" \
  "wrapper registered once on PreToolUse with matcher .*"
assert_eq "$(printf '%s' "$MANIFEST_BODY" | grep -c "file: 'kernel-mandate-role-gate\.sh'")" "0" \
  "raw kernel is NOT registered in HOOK_MANIFEST"
COMPANIONS=$(awk '/const HOOK_COMPANIONS = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL")
assert_eq "$(printf '%s' "$COMPANIONS" | grep -c "'kernel-mandate-role-gate\.sh'")" "1" \
  "raw kernel is copied as a companion (wrapper execs it)"
SUPERSEDED=$(awk '/const SUPERSEDED_REGISTRATIONS = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL")
assert_eq "$(printf '%s' "$SUPERSEDED" | grep -c "'kernel-mandate-role-gate\.sh'")" "1" \
  "a stale direct kernel registration is listed for pruning"

# ---------------------------------------------------------------------------
section "kernel wiring: the role ledger ships and is staged beside the mandate"
# ---------------------------------------------------------------------------
# A manifest is the machine's copy of the QA operating system; nobody
# reviews an OS by reading path globs. The ledger is the human copy — the
# ten roles, what each is REFUSED, the handovers and the review loops —
# rendered by `kernel-mandate doc` (npm run sync:kernel-mandate, which
# fails on drift) and staged by postinstall beside the manifest it
# describes. These assertions are about the two properties that make it
# worth trusting: it ships, and it claims nothing the manifest does not.
LEDGER="$HOOK_DIR/data/achilles-qa.kernel-mandate.md"
assert_eq "$([ -f "$LEDGER" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.kernel-mandate.md ships"
for ROLE in orchestrator scaffolder test-composer in-flight-composer workflow-reviewer \
            phase-validator process-validator batch-reviewer perf-reviewer selector-diff-validator; do
  assert_eq "$(grep -c "^### \`$ROLE\`" "$LEDGER")" "1" "ledger documents the $ROLE role exactly once"
done
assert_eq "$(grep -c '^\*\*May not\*\*' "$LEDGER")" "10" "every role carries a refusal list — the half a manifest states only by omission"
assert_eq "$(grep -c '^## Handover contracts' "$LEDGER")" "1" "the ledger names the handover contracts"
assert_eq "$(grep -c '^```mermaid' "$LEDGER")" "1" "the ledger carries the workflow flowchart"
# The approver roles hold no shell. The ledger must SAY so, in the section
# for one of them — a ledger that quietly widens a role is worse than none.
APPROVER_SECTION=$(awk '/^### `workflow-reviewer`/{p=1} p{print} p&&/^### `[a-z-]+`$/&&!/workflow-reviewer/{exit}' "$LEDGER")
assert_eq "$(printf '%s' "$APPROVER_SECTION" | grep -c 'run any shell command')" "1" "the ledger states that an approver role runs nothing"
assert_eq "$(printf '%s' "$APPROVER_SECTION" | grep -c '^- \*\*Runs\*\*')" "0" "and grants it no commands"
# Staged by postinstall on the same never-overwrite terms as the manifest.
assert_eq "$(grep -c "QA_LEDGER_FILE = 'achilles-qa.kernel-mandate.md'" "$POSTINSTALL")" "1" "postinstall knows the ledger file"
assert_eq "$(awk '/function stageProjectMandate/{p=1} p{print} p&&/^}/{exit}' "$POSTINSTALL" | grep -c "kernel-mandate.md")" "1" \
  "stageProjectMandate stages the ledger beside the manifest"

# ---------------------------------------------------------------------------
section "kernel wiring: the shipped QA mandate validates and matches its table"
# ---------------------------------------------------------------------------
assert_eq "$([ -f "$WORKFLOW" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.workflow.json ships"
assert_eq "$([ -f "$MANDATE" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.kernel-mandate.json ships"

if command -v node >/dev/null 2>&1 && node -e "require('ajv/dist/2020.js'); require('ajv-formats');" >/dev/null 2>&1; then
  SCHEMA_VERDICT=$(node -e "
    const Ajv = require('ajv/dist/2020.js'); const addFormats = require('ajv-formats');
    const fs = require('fs');
    const ajv = new Ajv({ strict: false, allErrors: true }); addFormats(ajv);
    const schema = JSON.parse(fs.readFileSync('$REPO_ROOT/schemas/kernel-mandate.schema.json', 'utf8'));
    const doc = JSON.parse(fs.readFileSync('$MANDATE', 'utf8'));
    const ok = ajv.validate(schema, doc);
    console.log(ok ? 'valid' : JSON.stringify(ajv.errors).slice(0, 300));
  " 2>&1)
  assert_eq "$SCHEMA_VERDICT" "valid" "staged manifest validates against the vendored kernel-mandate schema"
else
  echo "  ${CLR_DIM}(ajv not available — skipping schema validation of the QA mandate)${CLR_RST}"
fi

# Table ↔ manifest consistency and the two hard boundaries the design
# states: every role from the table is present (and only those), each
# binds its own agentType, the main session is the orchestrator, and no
# role's read scope names application source or the environment file.
TABLE_CHECK=$("$JQ" -rn --slurpfile wf "$WORKFLOW" --slurpfile m "$MANDATE" '
  ($wf[0]) as $w | ($m[0]) as $k |
  ($w.roles | keys | sort) as $wr | ($k.roles | keys | sort) as $kr |
  [
    (if $wr == $kr then "roles-match" else "roles-differ" end),
    (if $k.settings.mainSessionRole == "orchestrator" then "main=orchestrator" else "main=\($k.settings.mainSessionRole)" end),
    (if ([$k.roles | to_entries[] | select(.value.agentTypes != [.key])] | length) == 0 then "agentTypes=self" else "agentTypes-drift" end),
    (if ([$k.roles[] | (.read.allow // [])[] | select(. == "src/**" or . == ".env" or startswith("src/") or startswith(".env"))] | length) == 0 then "no-src-no-env" else "reads-src-or-env" end)
  ] | join(" ")')
assert_eq "$TABLE_CHECK" "roles-match main=orchestrator agentTypes=self no-src-no-env" \
  "manifest roles == table roles, main session is orchestrator, agentTypes bind by name, nothing reads src/** or .env"

# ---------------------------------------------------------------------------
section "kernel wiring: the QA mandate loads in the vendored kernel"
# ---------------------------------------------------------------------------
KW_TMP=$(mktemp -d)
KP="$KW_TMP/proj"
mkdir -p "$KP/.claude" "$KP/tests/e2e/docs" "$KP/src"
cp "$MANDATE" "$KP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_MANIFEST="$KP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_STATE_DIR="$KW_TMP/state"

# Main session (no agent_id) binds as orchestrator.
assert_deny "$KERNEL" "$(payload tool_name=Read file_path="$KP/src/app.ts" cwd="$KP")" \
  "orchestrator Read src/app.ts → DENY" "outside the role's read scope"
assert_deny "$KERNEL" "$(payload tool_name=Read file_path="$KP/.env" cwd="$KP")" \
  "orchestrator Read .env → DENY" "outside the role's read scope"
assert_allow "$KERNEL" "$(payload tool_name=Read file_path="$KP/package.json" cwd="$KP")" \
  "orchestrator Read package.json → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Write file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}' cwd="$KP")" \
  "orchestrator Write the ledger → ALLOW (SoD lives in the ledger write gate)"
assert_allow "$KERNEL" "$(payload tool_name=Write file_path="$KP/.gitignore" content='.achilles/' cwd="$KP")" \
  "orchestrator Write .gitignore → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npx playwright test --list' cwd="$KP")" \
  "orchestrator Bash npx playwright test --list → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command="git commit -m 'chore: scaffold e2e suite'" cwd="$KP")" \
  "orchestrator Bash git commit → ALLOW"
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npm install left-pad' cwd="$KP")" \
  "orchestrator Bash npm install → DENY" "may not run this command"
assert_allow "$KERNEL" "$(payload tool_name=Skill skill=onboarding cwd="$KP")" \
  "orchestrator Skill onboarding → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Agent description='workflow-reviewer-phase1: review phase 1' prompt='<<kernel-mandate-role: workflow-reviewer>>
Verify the ledger.' cwd="$KP")" \
  "orchestrator dispatches a tagged workflow-reviewer → ALLOW"

# Subagents bind by the host's agent_type. The kernel caches a binding per
# agent_id, so each role gets its own id — sharing one would re-use the
# first role for every later probe.
sub() { payload "$@" cwd="$KP" | "$JQ" -c '. + {agent_id: ("sub-" + .agent_type)}'; }
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=workflow-reviewer command='ls')" \
  "workflow-reviewer Bash → DENY (approvers have no shell)" "may not use the 'Bash' tool"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=workflow-reviewer file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "workflow-reviewer Write the ledger → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=workflow-reviewer file_path="$KP/tests/e2e/login.spec.ts" content='x')" \
  "workflow-reviewer Write a spec → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=perf-reviewer file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "perf-reviewer Write the e2e ledger → DENY" "outside the role's write scope"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/login.spec.ts" content='import { test } from "./fixtures/auth"; test("x", async () => {});')" \
  "test-composer Write a spec (relative import) → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Read agent_type=test-composer file_path="$KP/src/app.ts")" \
  "test-composer Read src/app.ts → DENY" "outside the role's read scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=selector-diff-validator file_path="$KP/tests/e2e/x.ts" content='x')" \
  "selector-diff-validator Write → DENY (writes nothing)" "may not use the 'Write' tool"

# ---------------------------------------------------------------------------
section "kernel wiring: runner config is the scaffolder's; imports are the composers'"
# ---------------------------------------------------------------------------
# The orchestrator both authors files and runs the runner, so the kernel's
# config screen refuses it the files a runner loads by convention. The
# table moves playwright.config.ts / package.json (and the Phase 1-2
# scaffold) to a write-only `scaffolder` — no shell, no dispatch — and the
# orchestrator's description names it, so the deny says where to go.
CFG_DENY=$(printf '%s' "$(payload tool_name=Write file_path="$KP/playwright.config.ts" content='export default {}' cwd="$KP")" | KERNEL_MANDATE_MANIFEST="$KERNEL_MANDATE_MANIFEST" KERNEL_MANDATE_STATE_DIR="$KERNEL_MANDATE_STATE_DIR" bash "$KERNEL" 2>/dev/null | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // ""')
assert_eq "$(printf '%s' "$CFG_DENY" | grep -c "may not write 'playwright.config.ts'")" "1" \
  "orchestrator Write playwright.config.ts → DENY (outside its write scope)"
assert_eq "$(printf '%s' "$CFG_DENY" | grep -c 'scaffolder')" "1" \
  "…and the reason names the scaffolder role as the author of that file"
assert_deny "$KERNEL" "$(payload tool_name=Write file_path="$KP/package.json" content='{}' cwd="$KP")" \
  "orchestrator Write package.json → DENY" "outside the role's write scope"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/playwright.config.ts" content='import { defineConfig } from "@playwright/test"; export default defineConfig({ reporter: [["html"], ["@civitas-cerebrum/achilles/reporter"]] });')" \
  "scaffolder (by agent_type) Write playwright.config.ts → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/package.json" content='{"scripts":{"test:repair":"achilles-self-repair"}}')" \
  "scaffolder Write package.json → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/tests/e2e/fixtures/auth.ts" content='import { test as base } from "@playwright/test"; export const test = base;')" \
  "scaffolder Write tests/e2e/fixtures/auth.ts importing the framework → ALLOW (authoring half runs nothing)"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/tests/e2e/page-repository.json" content='{}')" \
  "scaffolder Write tests/e2e/page-repository.json → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=scaffolder command='npx playwright test --list')" \
  "scaffolder Bash npx playwright test --list → DENY (never runs what it authored)" "may not use the 'Bash' tool"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=scaffolder command='ls')" \
  "scaffolder Bash ls → DENY (no shell at all)" "may not use the 'Bash' tool"
assert_deny "$KERNEL" "$(sub tool_name=Agent agent_type=scaffolder description='test-composer-j-x: compose' prompt='<<kernel-mandate-role: test-composer#ab12cd>>')" \
  "scaffolder Agent → DENY (no dispatch)" "may not use the 'Agent' tool"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/tests/e2e/login.spec.ts" content='x')" \
  "scaffolder Write a spec → DENY (scaffold only)" "outside the role's write scope"

# The composers author code AND run it, so their imports are screened
# against write.codeImports — declared in the table as exactly the two
# packages a spec legitimately imports (test-composer SKILL.md,
# element-interactions SKILL.md).
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/x.spec.ts" content='import { test } from "@playwright/test";')" \
  "test-composer Write a spec importing @playwright/test → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/x.spec.ts" content='import { test } from "@playwright/test"; import { ElementInteractions } from "@civitas-cerebrum/element-interactions";')" \
  "test-composer Write a spec importing @civitas-cerebrum/element-interactions → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/x.spec.ts" content='import fs from "fs"')" \
  "test-composer Write a spec importing fs → DENY" "filesystem access"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=in-flight-composer file_path="$KP/tests/e2e/x.spec.ts" content='import { test } from "@playwright/test";')" \
  "in-flight-composer Write a spec importing @playwright/test → ALLOW"
IMPORTS_CHECK=$("$JQ" -rn --slurpfile m "$MANDATE" '
  ($m[0].roles) as $r |
  [
    (if ($r["test-composer"].write.codeImports == ["@civitas-cerebrum/element-interactions","@playwright/test"]) then "composer-imports" else "composer-imports-drift" end),
    (if ($r["in-flight-composer"].write.codeImports == $r["test-composer"].write.codeImports) then "in-flight-same" else "in-flight-drift" end),
    (if ($r.scaffolder.tools.allow | index("Bash") == null and index("Agent") == null) then "scaffolder-no-bash-no-agent" else "scaffolder-has-shell-or-dispatch" end),
    (if ($r.orchestrator.write.allow | index("playwright.config.ts") == null and index("package.json") == null) then "orchestrator-no-config" else "orchestrator-writes-config" end),
    (if ($r.orchestrator.dispatch | index("scaffolder") != null) then "orchestrator-dispatches-scaffolder" else "no-scaffolder-dispatch" end)
  ] | join(" ")')
assert_eq "$IMPORTS_CHECK" "composer-imports in-flight-same scaffolder-no-bash-no-agent orchestrator-no-config orchestrator-dispatches-scaffolder" \
  "manifest: composers declare exactly the framework imports, scaffolder has no shell/dispatch, orchestrator writes no config and dispatches the scaffolder"

# ---------------------------------------------------------------------------
section "kernel wiring: dispatch grammar — every shape the skills teach binds, the old one is refused"
# ---------------------------------------------------------------------------
# disp <description> <tag line> [subagent_type] → an Agent payload from the
# orchestrator whose prompt opens with the tag, as the brief templates do.
disp() {
  payload tool_name=Agent description="$1" prompt="$2
Read the ledger at tests/e2e/docs/onboarding-status.json and verify the deliverables on disk." cwd="$KP" \
    | "$JQ" -c --arg t "${3:-}" 'if $t != "" then .tool_input.subagent_type = $t else . end'
}
# The scaffolder shapes are read out of the onboarding skill's own fenced
# templates (`description:` / `prompt:` lines), with <nonce> filled in —
# so the test dispatches exactly what the skill teaches.
ONB="$REPO_ROOT/skills/onboarding/SKILL.md"
tmpl_desc() { grep -m1 -E "^description:[[:space:]]+$1" "$ONB" | sed -E 's/^description:[[:space:]]+//'; }
tmpl_tag()  { grep -m1 -E "^prompt:[[:space:]]+<<kernel-mandate-role: $1#<nonce>>>" "$ONB" | sed -E 's/^prompt:[[:space:]]+//' | sed "s/<nonce>/$2/"; }
P1_DESC=$(tmpl_desc 'scaffolder-phase1:'); P1_TAG=$(tmpl_tag scaffolder k9x2a1)
P2_DESC=$(tmpl_desc 'scaffolder-phase2:'); P2_TAG=$(tmpl_tag scaffolder k9x2a2)
assert_eq "$([ -n "$P1_DESC" ] && [ -n "$P1_TAG" ] && [ -n "$P2_DESC" ] && [ -n "$P2_TAG" ] && echo found || echo missing)" "found" \
  "onboarding SKILL.md carries the scaffolder-phase1 / scaffolder-phase2 dispatch templates (description + tagged prompt)"
assert_allow "$KERNEL" "$(disp "$P1_DESC" "$P1_TAG" scaffolder)" \
  "onboarding Phase 1 template (from the skill text): orchestrator dispatches scaffolder-phase1 → ALLOW"
assert_allow "$KERNEL" "$(disp "$P2_DESC" "$P2_TAG" scaffolder)" \
  "onboarding Phase 2 template (from the skill text): orchestrator dispatches scaffolder-phase2 → ALLOW"
# Literal copies of the other skills' dispatch shapes (the skill each
# mirrors is named; the literals are pinned to the skill files below).
assert_allow "$KERNEL" "$(disp 'test-composer-j-login-flow: compose the login-flow journey' '<<kernel-mandate-role: test-composer#m3n4p5>>' test-composer)" \
  "test-composer SKILL.md / onboarding Phase 3: test-composer-j-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'test-composer-sj-checkout-1: cycle 1' '<<kernel-mandate-role: test-composer#m3n4p6>>' test-composer)" \
  "coverage-expansion: test-composer-sj-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'test-composer-secrets-sweep: extract literals to .env' '<<kernel-mandate-role: test-composer#m3n4p7>>' test-composer)" \
  "onboarding Phase 7 / secrets-sweep: test-composer-secrets-sweep + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'in-flight-composer-j-cart: heal the cart spec' '<<kernel-mandate-role: in-flight-composer#c1d2e3>>' in-flight-composer)" \
  "in-flight-composer-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'workflow-reviewer-phase3: review Phase 3' '<<kernel-mandate-role: workflow-reviewer#q7r8s9>>' workflow-reviewer)" \
  "workflow-reviewer SKILL.md / onboarding: workflow-reviewer-phase<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'workflow-reviewer-pass2: review Pass 2' '<<kernel-mandate-role: workflow-reviewer#q7r8t0>>' workflow-reviewer)" \
  "coverage-expansion: workflow-reviewer-pass<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'workflow-reviewer-cycle1: review cycle 1' '<<kernel-mandate-role: workflow-reviewer#q7r8t1>>' workflow-reviewer)" \
  "journey-mapping: workflow-reviewer-cycle<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase-validator-4: greenlight Phase 4' '<<kernel-mandate-role: phase-validator#z7a8b9>>' phase-validator)" \
  "phase-validator-<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'perf-reviewer-phase1: review perf Phase 1' '<<kernel-mandate-role: perf-reviewer#t1u2v3>>' perf-reviewer)" \
  "perf-onboarding: perf-reviewer-phase<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'perf-reviewer-pass-load: review the load pass' '<<kernel-mandate-role: perf-reviewer#t1u2v4>>' perf-reviewer)" \
  "perf-onboarding: perf-reviewer-pass-<kind> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'process-validator-stage-a-wave: validate the planned wave' '<<kernel-mandate-role: process-validator#w4x5y6>>' process-validator)" \
  "process-validator-workflow.md: process-validator-<scope> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'batch-reviewer-pass-1: cycle 1' '<<kernel-mandate-role: batch-reviewer#f4g5h6>>' batch-reviewer)" \
  "batch-reviewer-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'selector-diff-validator-run1: diff the selectors' '<<kernel-mandate-role: selector-diff-validator#i7j8k9>>' selector-diff-validator)" \
  "selector-diff-validator-<slug> + tag → ALLOW"
# A tag without subagent_type still binds (the type is optional; when
# present it must agree).
assert_allow "$KERNEL" "$(disp 'test-composer-j-login-flow: compose' '<<kernel-mandate-role: test-composer#m3n4p8>>')" \
  "tagged dispatch without subagent_type → ALLOW"
# Refused shapes — each deny names the fix.
assert_deny "$KERNEL" "$(disp 'composer-j-login-flow: compose the login-flow journey' '<<kernel-mandate-role: test-composer#m3n4p9>>' test-composer)" \
  "pre-kernel composer-j-<slug>: shape → DENY (names no manifest role)" "names no manifest role"
assert_deny "$KERNEL" "$(disp 'test-composer-j-login-flow: compose' 'Compose the journey.' test-composer)" \
  "test-composer-j-<slug>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'test-composer-j-login-flow: compose' '<<kernel-mandate-role: test-composer#n0n1n2>>' workflow-reviewer)" \
  "description names test-composer, subagent_type is workflow-reviewer → DENY" "subagent_type"
# A near-miss tag (nonce under 4 chars) and a tag for another role both
# leave the TARGET untagged, which is the check the kernel reports first.
assert_deny "$KERNEL" "$(disp 'test-composer-j-login-flow: compose' '<<kernel-mandate-role: test-composer#ab>>' test-composer)" \
  "nonce shorter than 4 chars → DENY (near-miss tag binds nothing)" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'test-composer-j-login-flow: compose' '<<kernel-mandate-role: workflow-reviewer#n0n1n3>>' test-composer)" \
  "tag names a different role than the description → DENY" "missing the binding tag"

# Drift pin: the skills still teach exactly these literals.
pin() { # <file> <literal> <name>
  assert_eq "$(grep -cF -- "$2" "$REPO_ROOT/$1")" "$3" "$4"
}
pin skills/test-composer/SKILL.md '<<kernel-mandate-role: test-composer#<nonce>>>' 1 "test-composer SKILL.md teaches the test-composer binding tag"
pin skills/test-composer/SKILL.md 'description: test-composer-j-<slug>: <task>' 1 "test-composer SKILL.md teaches the test-composer-j-<slug>: description"
pin skills/workflow-reviewer/SKILL.md '<<kernel-mandate-role: workflow-reviewer#<nonce>>>' 1 "workflow-reviewer SKILL.md teaches the workflow-reviewer binding tag"
pin skills/perf-onboarding/SKILL.md '<<kernel-mandate-role: perf-reviewer#<nonce>>>' 1 "perf-onboarding SKILL.md teaches the perf-reviewer binding tag"
pin skills/coverage-expansion/references/process-validator-workflow.md '<<kernel-mandate-role: process-validator#<nonce>>>' 1 "process-validator-workflow.md teaches the process-validator binding tag"
pin hooks/workflow-reviewer-brief-gate.sh '<<kernel-mandate-role: workflow-reviewer#<nonce>>>' 1 "the reviewer brief gate's fix template opens with the binding tag"
# The old literal may survive only in the sentence that retires it (the
# line names it "pre-kernel"); anywhere else it is a dispatch instruction
# the kernel would refuse.
assert_eq "$(grep -rhF -- '`composer-j-<slug>:`' "$REPO_ROOT/skills/onboarding" "$REPO_ROOT/skills/coverage-expansion" "$REPO_ROOT/skills/test-composer" "$REPO_ROOT/skills/workflow-reviewer" "$REPO_ROOT/skills/bug-discovery" "$REPO_ROOT/skills/secrets-sweep" 2>/dev/null | grep -vc 'pre-kernel' | tr -d ' ')" "0" \
  "no dispatching skill still teaches the pre-kernel \`composer-j-<slug>:\` description (outside the sentence retiring it)"

# ---------------------------------------------------------------------------
section "wrapper: dormant without a session marker, consults the kernel with one"
# ---------------------------------------------------------------------------
export ACHILLES_SESSION_STATE_DIR="$KW_TMP/sessions"
mkdir -p "$ACHILLES_SESSION_STATE_DIR"
DEV_TRANSCRIPT="$KW_TMP/dev-transcript.jsonl"
cat > "$DEV_TRANSCRIPT" <<'EOF'
{"type":"user","message":{"content":[{"type":"text","text":"tidy the README"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
EOF
# The one call the kernel would refuse for the orchestrator — used as the
# probe throughout so the only variable is whether the kernel was asked.
probe() { payload session_id="$1" transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KP/src/app.ts" cwd="$KP"; }

assert_allow "$H" "$(probe km-dev-1)" "dev session (no marker, no signal): wrapper → silent ALLOW (dormant)"
assert_deny "$KERNEL" "$(probe km-dev-1)" "…while the raw kernel would DENY the same call (manifest is live on disk)" "outside the role's read scope"

: > "$ACHILLES_SESSION_STATE_DIR/km-act-1.active"
assert_deny "$H" "$(probe km-act-1)" "marker present: wrapper relays the kernel's DENY" "outside the role's read scope"
assert_allow "$H" "$(payload session_id=km-act-1 transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KP/package.json" cwd="$KP")" \
  "marker present: in-scope Read relays the kernel's ALLOW"
export ACHILLES_PROTOCOL=0
assert_deny "$H" "$(probe km-act-1)" "ACHILLES_PROTOCOL=0 cannot deactivate a live marker → still DENY (one-way lifecycle)" "outside the role's read scope"
assert_allow "$H" "$(probe km-dev-2)" "ACHILLES_PROTOCOL=0 suppresses activation for a fresh session → ALLOW"
unset ACHILLES_PROTOCOL
export KERNEL_MANDATE=0
assert_allow "$H" "$(probe km-act-1)" "KERNEL_MANDATE=0 (operator shell) bypasses through the wrapper → ALLOW"
unset KERNEL_MANDATE

# Activation on the very first protocol-shaped call: the wrapper sees the
# Skill invocation, marks the session, and consults the kernel for it.
assert_allow "$H" "$(payload session_id=km-act-2 transcript_path="$DEV_TRANSCRIPT" tool_name=Skill skill=onboarding cwd="$KP")" \
  "first protocol-shaped call (Skill onboarding) → kernel consulted → ALLOW"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/km-act-2.active" ] && echo marked || echo unmarked)" "marked" \
  "…and the session is now marked active"
assert_deny "$H" "$(probe km-act-2)" "…so the next out-of-scope call is DENIED" "outside the role's read scope"

# Missing session identity fails closed (guards on) — the kernel is asked.
assert_deny "$H" "$(payload tool_name=Read file_path="$KP/src/app.ts" cwd="$KP")" \
  "no session_id: fail-closed → kernel consulted → DENY" "outside the role's read scope"

# Kernel script absent beside the wrapper → nothing to consult → silent allow.
NOK="$KW_TMP/hooks-without-kernel"
mkdir -p "$NOK/lib"
cp "$H" "$NOK/"
cp "$HOOK_DIR"/lib/achilles-activation.sh "$NOK/lib/"
assert_allow "$NOK/achilles-kernel-activation-gate.sh" "$(probe km-act-1)" \
  "marker present but kernel script missing → silent ALLOW (achilles' own gates still apply)"

unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR ACHILLES_SESSION_STATE_DIR

# ---------------------------------------------------------------------------
section "postinstall: stages the QA mandate into the project, never overwrites, prunes the direct kernel registration"
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  WIRE_TEST=$(mktemp "$KW_TMP/wiring-XXXXXX.mjs")
  WIRE_HOME="$KW_TMP/home"
  WIRE_PROJ="$KW_TMP/consumer"
  mkdir -p "$WIRE_HOME/.claude/hooks" "$WIRE_PROJ"
  cat > "$WIRE_TEST" <<EOF
import { strict as assert } from 'assert';
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
const home = '$WIRE_HOME';
const proj = '$WIRE_PROJ';
const userHooks = path.join(home, '.claude', 'hooks');
const settingsPath = path.join(home, '.claude', 'settings.json');
// An upgraded install: the raw kernel is registered directly AND present on disk,
// so the dangling-file prune alone would keep it.
// The stale kernel predates the package (copyHookFile copies on mtime), as
// on any real upgrade — backdate the stub or the test would be testing the
// mtime rule instead of the companion copy.
const staleKernel = path.join(userHooks, 'kernel-mandate-role-gate.sh');
fs.writeFileSync(staleKernel, '#!/bin/bash\nexit 0\n');
const past = new Date(Date.now() - 7 * 24 * 3600 * 1000);
fs.utimesSync(staleKernel, past, past);
fs.writeFileSync(settingsPath, JSON.stringify({ hooks: { PreToolUse: [
  { matcher: '.*', hooks: [ { type: 'command', command: path.join(userHooks, 'kernel-mandate-role-gate.sh'), timeout: 10 } ] },
] } }, null, 2));
process.env.HOME = home;
process.env.CIVITAS_SKIP_JQ_INSTALL = '1';
delete process.env.CIVITAS_SKIP_HOOK_INSTALL;
const require = createRequire(import.meta.url);
const pi = require(path.join('$REPO_ROOT', 'scripts', 'postinstall.js'));

// --- hooks: wrapper registered, direct kernel registration pruned, kernel copied as companion
pi.installCivitasHooks();
const after = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const star = after.hooks.PreToolUse.filter(g => g.matcher === '.*');
const starCmds = star.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(starCmds.some(c => c.endsWith('achilles-kernel-activation-gate.sh')), 'wrapper registered on PreToolUse:.*');
const allCmds = after.hooks.PreToolUse.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(!allCmds.some(c => c.endsWith('kernel-mandate-role-gate.sh')), 'direct kernel registration pruned');
const kernelOnDisk = path.join(userHooks, 'kernel-mandate-role-gate.sh');
assert.ok(fs.existsSync(kernelOnDisk), 'kernel still on disk (companion)');
assert.ok(fs.statSync(kernelOnDisk).size > 1000, 'companion copy is the real kernel, not the stub');
assert.ok(fs.existsSync(path.join(userHooks, 'lib', 'kernel-mandate.sh')), 'kernel lib copied');
assert.ok(fs.existsSync(path.join(userHooks, 'data', 'achilles-qa.kernel-mandate.json')), 'hooks/data manifest copied');

// --- staging: lands only when absent
const dest = path.join(proj, '.claude', 'kernel-mandate.json');
assert.ok(!fs.existsSync(dest), 'precondition: no manifest in the project');
pi.stageProjectMandate(proj);
assert.ok(fs.existsSync(dest), 'manifest staged into <project>/.claude/');
const shipped = fs.readFileSync(path.join('$REPO_ROOT', 'hooks', 'data', 'achilles-qa.kernel-mandate.json'), 'utf8');
assert.equal(fs.readFileSync(dest, 'utf8'), shipped, 'staged bytes == shipped bytes');
// nothing outside the project
assert.ok(!fs.existsSync(path.join(home, '.claude', 'kernel-mandate.json')), 'nothing staged under HOME');

// --- never overwrites
const custom = '{"kernelMandateVersion":1,"name":"custom","roles":{}}\n';
fs.writeFileSync(dest, custom);
pi.stageProjectMandate(proj);
assert.equal(fs.readFileSync(dest, 'utf8'), custom, 'existing manifest left byte-for-byte alone');

// --- honours the hook-install opt-out (no hooks → no kernel → nothing to bind)
const proj2 = path.join('$KW_TMP', 'consumer-skip');
fs.mkdirSync(proj2, { recursive: true });
process.env.CIVITAS_SKIP_HOOK_INSTALL = '1';
pi.stageProjectMandate(proj2);
assert.ok(!fs.existsSync(path.join(proj2, '.claude', 'kernel-mandate.json')), 'not staged under CIVITAS_SKIP_HOOK_INSTALL=1');
console.log('WIRING_OK');
EOF
  TESTS_RUN=$((TESTS_RUN + 1))
  WIRE_OUT=$(HOME="$WIRE_HOME" node "$WIRE_TEST" 2>&1 || true)
  if echo "$WIRE_OUT" | grep -q 'WIRING_OK'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} postinstall wires the wrapper, prunes the direct kernel registration, stages the mandate once and never overwrites"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("postinstall kernel wiring: ${WIRE_OUT:0:400}")
    echo "${CLR_FAIL}  ✗${CLR_RST} postinstall kernel wiring ${CLR_DIM}(${WIRE_OUT:0:160})${CLR_RST}"
  fi
else
  echo "  ${CLR_DIM}(node not on PATH — skipping postinstall wiring test)${CLR_RST}"
fi

rm -rf "$KW_TMP"
