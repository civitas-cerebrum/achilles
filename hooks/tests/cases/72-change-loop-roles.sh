#!/bin/bash
# Tests for the change-loop roles in the QA mandate — implementer,
# task-reviewer, verifier, live-inspector, doc-author — in
# hooks/data/achilles-qa.kernel-mandate.json.
#
# Contract under test:
#   - the manifest carries the five roles, each described; each binds its own
#     agentType; only the orchestrator dispatches them; none reads src/**
#     or .env; exactly one role may write each evidence deliverable.
#   - every dispatch shape the change loop teaches — `implementer-<change>:`,
#     `task-reviewer-<change>:`, `verifier-<change>:`,
#     `live-inspector-<slug>:`, `doc-author-<slug>:` — with the
#     `<<kernel-mandate-role: ROLE#nonce>>` tag as the brief's first line
#     is ALLOWED; the same description without the tag is DENIED.
#   - separation of duties holds at the path level: the implementer may
#     not write the page repository or any verdict; the reviewer and the
#     verifier write only their own note; the doc author writes no
#     evidence; the orchestrator cannot write verify.md at all, so it
#     cannot set `Status: complete` on a change it drove.
#   - spend layering: the kernel lets the verifier run the test runner
#     (authority), and the project's spend gate refuses a spend-incurring
#     spec without the project's spend opt-in (content).

KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
MANDATE="$HOOK_DIR/data/achilles-qa.kernel-mandate.json"
SPEND_GATE="$HOOK_DIR/factory/spend-gate.sh"
NEW_ROLES="implementer task-reviewer verifier live-inspector doc-author"

# ---------------------------------------------------------------------------
section "change-loop roles: the manifest carries the five roles"
# ---------------------------------------------------------------------------
for ROLE in $NEW_ROLES; do
  assert_eq "$("$JQ" -r --arg r "$ROLE" '.roles[$r].description // "" | length > 0' "$MANDATE")" "true" \
    "manifest: $ROLE carries a description"
  assert_eq "$("$JQ" -r --arg r "$ROLE" '.roles[$r].agentTypes == [$r]' "$MANDATE")" "true" \
    "manifest: $ROLE binds its own agentType"
  assert_eq "$("$JQ" -r --arg r "$ROLE" '(.roles[$r].dispatch // []) | length' "$MANDATE")" "0" \
    "manifest: $ROLE dispatches nothing"
  assert_eq "$("$JQ" -r --arg r "$ROLE" '.roles.orchestrator.dispatch | index($r) != null' "$MANDATE")" "true" \
    "manifest: the orchestrator may summon $ROLE"
done

# One writer per evidence deliverable. A literal glob check is enough here:
# the scopes are declared literally in the manifest, and the kernel probes
# below prove the same property by decision.
ONE_WRITER=$("$JQ" -rn --slurpfile m "$MANDATE" '
  ($m[0].roles) as $r |
  def writers($g): [$r | to_entries[] | select((.value.write.allow // []) | index($g) != null) | .key];
  [
    (if writers("docs/evidence/*/verify.md") == ["verifier"] then "verify=verifier" else "verify=\(writers("docs/evidence/*/verify.md"))" end),
    (if writers("docs/evidence/*/review.md") == ["task-reviewer"] then "review=task-reviewer" else "review=\(writers("docs/evidence/*/review.md"))" end),
    (if writers("docs/evidence/*/report.md") == ["implementer"] then "report=implementer" else "report=\(writers("docs/evidence/*/report.md"))" end),
    (if ($r.implementer.write.deny // []) | index("**/page-repository*.json") != null then "implementer-no-repository" else "implementer-writes-repository" end),
    (if ($r["doc-author"].write.deny // []) | index("docs/evidence/**") != null then "doc-author-no-evidence" else "doc-author-writes-evidence" end),
    (if ([$r | to_entries[] | select(.key != "doc-author") | (.value.write.allow // [])[] | select(. == "docs/**" or . == "docs/evidence/**")] | length) == 0 then "no-blanket-evidence-writer" else "blanket-evidence-writer" end),
    (if ($r["doc-author"].tools.allow // []) | index("Bash") == null then "doc-author-no-shell" else "doc-author-has-shell" end),
    (if ([$r | to_entries[] | select(.key as $k | ["implementer","task-reviewer","verifier","live-inspector","doc-author"] | index($k)) | (.value.read.allow // [])[] | select(. == "src/**" or startswith("src/") or startswith(".env"))] | length) == 0 then "no-src-no-env" else "reads-src-or-env" end)
  ] | join(" ")')
assert_eq "$ONE_WRITER" "verify=verifier review=task-reviewer report=implementer implementer-no-repository doc-author-no-evidence no-blanket-evidence-writer doc-author-no-shell no-src-no-env" \
  "manifest: one writer per evidence note, carve-outs present, no blanket evidence writer, doc author has no shell, nothing reads src/** or .env"

# ---------------------------------------------------------------------------
section "change-loop roles: dispatch grammar — tagged shapes bind, untagged are refused"
# ---------------------------------------------------------------------------
CL_TMP=$(mktemp -d)
CP="$CL_TMP/proj"
mkdir -p "$CP/.claude" "$CP/tests/e2e/docs" "$CP/tests/e2e/north" "$CP/tests/e2e/south" "$CP/tests/e2e/inspect" \
         "$CP/docs/evidence/2026-01-01-basket-total/" "$CP/docs/evidence/selectors" "$CP/.claude/skills/shop-notes" "$CP/src"
cp "$MANDATE" "$CP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_MANIFEST="$CP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_STATE_DIR="$CL_TMP/state"
EV="docs/evidence/2026-01-01-basket-total"

# disp <description> <tag line> [subagent_type] → an Agent payload from the
# orchestrator (main session) whose prompt opens with the tag.
disp() {
  payload tool_name=Agent description="$1" prompt="$2
Read the brief at $EV/brief.md first." cwd="$CP" \
    | "$JQ" -c --arg t "${3:-}" 'if $t != "" then .tool_input.subagent_type = $t else . end'
}
assert_allow "$KERNEL" "$(disp 'implementer-basket-total: implement the basket total change' '<<kernel-mandate-role: implementer#c1a2b3>>' implementer)" \
  "implementer-<change>: + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'task-reviewer-basket-total: review the basket total change' '<<kernel-mandate-role: task-reviewer#c1a2b4>>' task-reviewer)" \
  "task-reviewer-<change>: + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'verifier-basket-total: verify the basket total change' '<<kernel-mandate-role: verifier#c1a2b5>>' verifier)" \
  "verifier-<change>: + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'live-inspector-checkout-pay-button: inspect the pay button' '<<kernel-mandate-role: live-inspector#c1a2b6>>' live-inspector)" \
  "live-inspector-<slug>: + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'doc-author-spend-classes: document the spend classes' '<<kernel-mandate-role: doc-author#c1a2b7>>' doc-author)" \
  "doc-author-<slug>: + tag → ALLOW"
assert_allow "$KERNEL" "$(disp 'verifier-basket-total: verify' '<<kernel-mandate-role: verifier#c1a2b8>>')" \
  "tagged verifier dispatch without subagent_type → ALLOW"

assert_deny "$KERNEL" "$(disp 'implementer-basket-total: implement' 'Implement the change.' implementer)" \
  "implementer-<change>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'task-reviewer-basket-total: review' 'Review the change.' task-reviewer)" \
  "task-reviewer-<change>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'verifier-basket-total: verify' 'Verify the change.' verifier)" \
  "verifier-<change>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'live-inspector-checkout-pay-button: inspect' 'Inspect the pay button.' live-inspector)" \
  "live-inspector-<slug>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'doc-author-spend-classes: document' 'Document the spend classes.' doc-author)" \
  "doc-author-<slug>: without the binding tag → DENY" "missing the binding tag"
assert_deny "$KERNEL" "$(disp 'implementer-basket-total: implement' '<<kernel-mandate-role: verifier#c1a2b9>>' implementer)" \
  "tag names the verifier, description names the implementer → DENY" "missing the binding tag"

# ---------------------------------------------------------------------------
section "change-loop roles: separation of duties at the path level"
# ---------------------------------------------------------------------------
# Subagents bind by agent_type; one agent_id per role (the kernel caches a
# binding per agent_id).
sub() { payload "$@" cwd="$CP" | "$JQ" -c '. + {agent_id: ("cl-" + .agent_type)}'; }
SPEC='import { test } from "@playwright/test"; test("CHK-01 — basket shows the item total", async () => {});'

# implementer
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/tests/e2e/north/basket.spec.ts" content="$SPEC")" \
  "implementer Write a spec → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/$EV/report.md" content='# Report')" \
  "implementer Write its report.md → ALLOW"
# Live inspection owns the page repository because a selector written from memory
# is a guess, so the deny is a glob that covers the repository wherever a project
# puts it; every path below has to be covered by it.
for REPO_PATH in \
  tests/e2e/page-repository.json \
  tests/data/page-repository.json \
  page-repository.json \
  tests/e2e/north/page-repository.checkout.json
do
  assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/$REPO_PATH" content='{}')" \
    "implementer Write $REPO_PATH → DENY (live inspection owns the page repository)" "explicitly denied"
done
# …and the glob must not swallow the spec and support files the implementer IS
# the author of, which happen to sit in the same trees.
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/tests/data/basket-items.json" content='[]')" \
  "implementer Write tests/data/basket-items.json → ALLOW (not a page repository)"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/tests/e2e/fixtures/repository-helpers.ts" content='export const x = 1;')" \
  "implementer Write a file whose name merely contains \"repository\" → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/$EV/verify.md" content='Status: complete')" \
  "implementer Write verify.md → DENY (never verifies its own change)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=implementer file_path="$CP/$EV/review.md" content='Approved')" \
  "implementer Write review.md → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Agent agent_type=implementer description='verifier-basket-total: verify' prompt='<<kernel-mandate-role: verifier#d4e5f6>>')" \
  "implementer Agent → DENY (no dispatch)" "may not use the 'Agent' tool"
assert_allow "$KERNEL" "$(sub tool_name=Bash agent_type=implementer command='npx tsc --noEmit')" \
  "implementer Bash type check → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=implementer command='npm run verify')" \
  "implementer Bash npm run verify → DENY (closure is the orchestrator's)" "may not run this command"

assert_deny "$KERNEL" "$(sub tool_name=Edit agent_type=implementer file_path="$CP/$EV/verify.md" old_string='Status: in verification' new_string='Status: complete')" \
  "implementer Edit verify.md → DENY (Edit is held to the same scope as Write)" "outside the role's write scope"

# task-reviewer
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=task-reviewer file_path="$CP/$EV/review.md" content='# Review')" \
  "task-reviewer Write review.md → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=task-reviewer file_path="$CP/$EV/verify.md" content='Status: complete')" \
  "task-reviewer Write verify.md → DENY (the reviewer cannot close a change)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=task-reviewer file_path="$CP/tests/e2e/north/basket.spec.ts" content="$SPEC")" \
  "task-reviewer Write a spec → DENY (reads, never fixes)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=task-reviewer command='npx playwright test tests/e2e/north/basket.spec.ts')" \
  "task-reviewer Bash test runner → DENY (never runs the app)" "may not run this command"
assert_allow "$KERNEL" "$(sub tool_name=Bash agent_type=task-reviewer command='npm run test:hooks')" \
  "task-reviewer Bash hook fixture runner → ALLOW"

# verifier
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=verifier file_path="$CP/$EV/verify.md" content='Status: complete')" \
  "verifier Write verify.md with Status: complete → ALLOW (the approver-class writer)"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=verifier file_path="$CP/tests/e2e/north/basket.spec.ts" content="$SPEC")" \
  "verifier Write a spec → DENY (never fixes code)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=verifier file_path="$CP/$EV/review.md" content='Approved')" \
  "verifier Write review.md → DENY" "outside the role's write scope"

assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=verifier file_path="$CP/$EV/report.md" content='# Report')" \
  "verifier Write report.md → DENY (the implementer's note)" "outside the role's write scope"

# live-inspector
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/tests/e2e/inspect/pay-button.spec.ts" content="$SPEC")" \
  "live-inspector Write an inspection spec under the inspect dir → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/$EV/proposal-pay-button.md" content='# Proposal')" \
  "live-inspector Write its proposal → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/docs/evidence/selectors/checkout-pay-button.md" content='# Evidence')" \
  "live-inspector Write selector evidence → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/tests/e2e/page-repository.json" content='{}')" \
  "live-inspector Write the page repository → DENY (proposes, never edits)" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/tests/e2e/north/basket.spec.ts" content="$SPEC")" \
  "live-inspector Write a suite spec → DENY" "outside the role's write scope"

assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/$EV/verify.md" content='Status: complete')" \
  "live-inspector Write verify.md → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=live-inspector file_path="$CP/$EV/review.md" content='Approved')" \
  "live-inspector Write review.md → DENY" "outside the role's write scope"

# doc-author
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=doc-author file_path="$CP/docs/spend-classes.md" content='# Spend classes')" \
  "doc-author Write docs/** → ALLOW"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=doc-author file_path="$CP/CLAUDE.md" content='# Project rules')" \
  "doc-author Write CLAUDE.md → ALLOW (declares no code constraints, so the agent-instructions screen does not apply)"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=doc-author file_path="$CP/.claude/skills/shop-notes/SKILL.md" content='# Shop notes')" \
  "doc-author Write a project skill → ALLOW"
for NOTE in verify review report; do
  assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=doc-author file_path="$CP/$EV/$NOTE.md" content='x')" \
    "doc-author Write $NOTE.md → DENY (evidence is carved out of docs/**)" "explicitly denied"
done
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=doc-author command='ls')" \
  "doc-author Bash → DENY (no shell)" "may not use the 'Bash' tool"

# orchestrator (main session: no agent_id)
assert_allow "$KERNEL" "$(payload tool_name=Write file_path="$CP/$EV/brief.md" content='# Brief' cwd="$CP")" \
  "orchestrator Write the change brief → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npm run verify' cwd="$CP")" \
  "orchestrator Bash npm run verify → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npm run change:start -- basket-total' cwd="$CP")" \
  "orchestrator Bash npm run change:start → ALLOW"

# ---------------------------------------------------------------------------
section "change-loop roles: verify.md Status: complete is approver-class"
# ---------------------------------------------------------------------------
# The orchestrator drove the change; it may not be the one that declares it
# verified. The manifest makes that a path decision (only the verifier's scope
# names verify.md); a project that widens a scope keeps the field-level
# rule in its own gate.
assert_deny "$KERNEL" "$(payload tool_name=Write file_path="$CP/$EV/verify.md" content='# Verify
Status: complete' cwd="$CP")" \
  "orchestrator Write verify.md with Status: complete → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(payload tool_name=Edit file_path="$CP/$EV/verify.md" old_string='Status: in verification' new_string='Status: complete' cwd="$CP")" \
  "orchestrator Edit verify.md to Status: complete → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(payload tool_name=Bash command="npm run verify > $EV/verify.md" cwd="$CP")" \
  "orchestrator redirects into verify.md → DENY (redirects are held to the write scope)" "outside the role's write scope"

# ---------------------------------------------------------------------------
section "change-loop roles: the verifier's spend-incurring runs need the project's spend opt-in"
# ---------------------------------------------------------------------------
# Authority vs content: the kernel decides WHO may run the test runner;
# the project's spend gate decides WHICH specs need the opt-in. The spend
# list, the opt-in name and the flag come from the project's rule file.
SPEND_SPEC="tests/e2e/south/checkout-order.spec.ts"
assert_allow "$KERNEL" "$(sub tool_name=Bash agent_type=verifier command="npx playwright test $SPEND_SPEC")" \
  "kernel: verifier runs the test runner → ALLOW (authority only; spend is the gate's call)"
assert_allow "$KERNEL" "$(sub tool_name=Bash agent_type=verifier command="SPEND_OPT_IN=1 npx playwright test $SPEND_SPEC")" \
  "kernel: verifier sets the project's spend opt-in (granted in bash.env) → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=implementer command="SPEND_OPT_IN=1 npx playwright test $SPEND_SPEC")" \
  "kernel: implementer sets the spend opt-in (not granted) → DENY" "SPEND_OPT_IN"

mkdir -p "$CP/scripts"
printf '%s\n' "{\"specs\":[\"$SPEND_SPEC\"]}" > "$CP/scripts/spend-list.json"
printf '%s\n' '{"version":1,"rules":{"spend.opt-in":{"list":"scripts/spend-list.json","optInEnv":"SPEND_OPT_IN","optInFlag":"--include-spend"}}}' > "$CP/achilles-factory-rules.json"
: > "$CP/$SPEND_SPEC"
export FACTORY_RULES="$CP/achilles-factory-rules.json"
export CLAUDE_PROJECT_DIR="$CP"
assert_deny "$SPEND_GATE" "$(sub tool_name=Bash agent_type=verifier command="npx playwright test $SPEND_SPEC")" \
  "spend gate: verifier runs a spend-incurring spec without the opt-in → DENY" "spend.opt-in"
assert_allow "$SPEND_GATE" "$(sub tool_name=Bash agent_type=verifier command="SPEND_OPT_IN=1 npx playwright test $SPEND_SPEC")" \
  "spend gate: the same run with the project's spend opt-in → ALLOW"
assert_allow "$SPEND_GATE" "$(sub tool_name=Bash agent_type=verifier command='npx playwright test tests/e2e/north/basket.spec.ts')" \
  "spend gate: a disposable-basket spec needs no opt-in → ALLOW"
unset FACTORY_RULES CLAUDE_PROJECT_DIR

unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR
rm -rf "$CL_TMP"
