#!/bin/bash
# Tests for the change-loop roles in the QA mandate — implementer,
# task-reviewer, verifier, live-inspector, doc-author — in
# hooks/data/achilles-qa.kernel-mandate.json.
#
# Contract under test:
#   - the manifest carries the five roles, each described; each binds its own
#     agentType; only the orchestrator dispatches them; none reads src/**
#     or .env; exactly one role may write each evidence deliverable.
#   - the project's spend gate refuses a spend-incurring spec the verifier
#     runs without the project's spend opt-in.

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
# the scopes are declared literally in the manifest.
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

CL_TMP=$(mktemp -d)
CP="$CL_TMP/proj"
mkdir -p "$CP/tests/e2e/north" "$CP/tests/e2e/south"
sub() { payload "$@" cwd="$CP" | "$JQ" -c '. + {agent_id: ("cl-" + .agent_type)}'; }

# ---------------------------------------------------------------------------
section "change-loop roles: the verifier's spend-incurring runs need the project's spend opt-in"
# ---------------------------------------------------------------------------
# The project's spend gate decides WHICH specs need the opt-in. The spend
# list, the opt-in name and the flag come from the project's rule file.
SPEND_SPEC="tests/e2e/south/checkout-order.spec.ts"
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

rm -rf "$CL_TMP"
