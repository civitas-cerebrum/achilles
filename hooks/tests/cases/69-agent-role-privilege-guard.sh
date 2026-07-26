#!/bin/bash
# Tests for agent-role-privilege-guard.sh — agentic-OS privilege
# enforcement on PreToolUse:Bash + PreToolUse:Agent. Role resolution:
# parent_tool_use_id → process table, then -s=<slug> role claim, then
# liveness (single role / intersection), then unconfined fail-open.
H="$HOOK_DIR/agent-role-privilege-guard.sh"

# Isolated test repo with a live pipeline ledger + a seeded process table.
TMPPG=$(mktemp -d)
trap 'rm -rf "$TMPPG"' EXIT
( cd "$TMPPG" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
mkdir -p "$TMPPG/tests/e2e/docs" "$TMPPG/.achilles"
TBL="$TMPPG/.achilles/.agent-process-table.json"
LEDGER="$TMPPG/tests/e2e/docs/onboarding-status.json"

NOW=$(date +%s)
seed_table() {
  # seed_table <role1> [role2 ...] — one live entry per role, id toolu_<role>.
  local json="{}" r
  for r in "$@"; do
    json=$(echo "$json" | "$JQ" -c --arg r "$r" --argjson now "$NOW" '
      . + { ("toolu_" + $r): { role: $r, denied: [], description: $r, ts: $now } }')
  done
  echo "$json" > "$TBL"
}

# ---------------------------------------------------------------------------
section "privilege-guard: tool-name filtering + fail-open"
assert_allow "$H" "$(payload tool_name=Write file_path=/tmp/x content=y cwd="$TMPPG")" "Write → silent allow"
rm -f "$TBL" "$LEDGER"
assert_allow "$H" "$(payload tool_name=Bash command='cat tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG")" \
  "orchestrator cat spec, NO live pipeline → silent allow (not policed)"

# ---------------------------------------------------------------------------
section "privilege-guard: orchestrator payload-ingest (pipeline live)"
echo '{"currentPhase": 5}' > "$LEDGER"
assert_deny "$H" "$(payload tool_name=Bash command='cat tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG")" \
  "orchestrator cat spec source → deny" "payload-ingest"
assert_deny "$H" "$(payload tool_name=Bash command='head -80 tests/e2e/docs/.subagent-returns/probe-j-checkout.md' cwd="$TMPPG")" \
  "orchestrator head spill return → deny" "payload-ingest"
assert_deny "$H" "$(payload tool_name=Bash command='tail -n 200 test-results/checkout/trace.zip' cwd="$TMPPG")" \
  "orchestrator tail trace artifact → deny" "payload-ingest"
# Adjacent allows: metadata reads + non-payload dumps.
assert_allow "$H" "$(payload tool_name=Bash command='wc -l tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG")" \
  "orchestrator wc -l spec (metadata) → allow"
assert_allow "$H" "$(payload tool_name=Bash command='grep -c test tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG")" \
  "orchestrator grep -c spec (count) → allow"
assert_allow "$H" "$(payload tool_name=Bash command='cat package.json' cwd="$TMPPG")" \
  "orchestrator cat non-payload file → allow"
assert_allow "$H" "$(payload tool_name=Bash command='ls test-results/' cwd="$TMPPG")" \
  "orchestrator ls artifact dir (not a dump) → allow"

# ---------------------------------------------------------------------------
section "privilege-guard: reviewer family loses mutate (parent_tool_use_id resolution)"
seed_table reviewer-inloop composer cleanup
assert_deny "$H" "$(payload tool_name=Bash command="sed -i 's/late/early/' tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer sed -i on spec → deny" "'mutate'"
assert_deny "$H" "$(payload tool_name=Bash command='git commit -m "fix: adjust expectations"' cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer git commit → deny" "'mutate'"
assert_deny "$H" "$(payload tool_name=Bash command='echo "verdict" > tests/e2e/docs/review-notes.md' cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer redirect into project → deny" "'mutate'"
# Adjacent allows: reads, scratch writes, and the payload-ingest class NOT crossing over.
assert_allow "$H" "$(payload tool_name=Bash command='git diff tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer git diff → allow"
assert_allow "$H" "$(payload tool_name=Bash command='echo scratch > /tmp/reviewer-notes.txt' cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer scratch redirect to /tmp → allow"
assert_allow "$H" "$(payload tool_name=Bash command='cat tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer cat spec in OWN context → allow (payload-ingest is orchestrator-only)"
assert_allow "$H" "$(payload tool_name=Bash command="node -e 'if (a > b) process.exit(1)'" cwd="$TMPPG" agent_id=sub_rev parent_tool_use_id=toolu_reviewer-inloop)" \
  "reviewer quoted > (comparison, not redirect) → allow"

# ---------------------------------------------------------------------------
section "privilege-guard: composer keeps mutate, loses remote-push"
assert_allow "$H" "$(payload tool_name=Bash command='git commit -m "test(j-checkout): add error-state cases (pass 2)"' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer git commit → allow"
assert_allow "$H" "$(payload tool_name=Bash command='mkdir -p tests/e2e/journeys && touch tests/e2e/journeys/checkout.spec.ts' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer filesystem writes → allow"
assert_deny "$H" "$(payload tool_name=Bash command='git push origin main' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer git push → deny" "'remote-push'"
assert_deny "$H" "$(payload tool_name=Bash command='git -c push.default=simple push' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer wrapped git -c ... push → deny" "'remote-push'"
assert_allow "$H" "$(payload tool_name=Bash command='echo "git push happens after review"' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer mentioning git push in a string → allow"

# ---------------------------------------------------------------------------
section "privilege-guard: text-only roles lose browser"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=cleanup-pass5-x open https://app.example.com' cwd="$TMPPG" agent_id=sub_cl parent_tool_use_id=toolu_cleanup)" \
  "cleanup playwright-cli open → deny" "'browser'"
assert_allow "$H" "$(payload tool_name=Bash command='wc -l tests/e2e/docs/adversarial-findings.md' cwd="$TMPPG" agent_id=sub_cl parent_tool_use_id=toolu_cleanup)" \
  "cleanup text-only read → allow"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-checkout-1-c1 open https://app.example.com' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer playwright-cli → allow (browser-privileged role)"

# ---------------------------------------------------------------------------
section "privilege-guard: -s=<slug> role claim when parent id is absent"
rm -f "$TBL"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=cleanup-ledger-x open https://app.example.com' cwd="$TMPPG" agent_id=sub_x)" \
  "no table, cleanup slug claim + browser → deny" "'browser'"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=probe-j-checkout-4 open https://app.example.com' cwd="$TMPPG" agent_id=sub_x)" \
  "no table, probe slug claim + browser → allow"

# ---------------------------------------------------------------------------
section "privilege-guard: liveness fallback — single role, intersection, unconfined weakening"
seed_table workflow-reviewer
assert_deny "$H" "$(payload tool_name=Bash command='rm -rf tests/e2e/journeys' cwd="$TMPPG" agent_id=sub_y)" \
  "single live role (workflow-reviewer) + rm → deny" "'mutate'"
seed_table reviewer-inloop composer
assert_allow "$H" "$(payload tool_name=Bash command='git commit -m "test(j-checkout): happy path (pass 1)"' cwd="$TMPPG" agent_id=sub_y)" \
  "ambiguous reviewer+composer + git commit → allow (composer holds mutate)"
assert_deny "$H" "$(payload tool_name=Bash command='git push origin main' cwd="$TMPPG" agent_id=sub_y)" \
  "ambiguous reviewer+composer + git push → deny (both deny remote-push)" "'remote-push'"
seed_table reviewer-inloop unconfined
assert_allow "$H" "$(payload tool_name=Bash command='git push origin main' cwd="$TMPPG" agent_id=sub_y)" \
  "ambiguous reviewer+unconfined + git push → allow (unconfined weakens intersection)"
rm -f "$TBL"
assert_allow "$H" "$(payload tool_name=Bash command='git push origin main' cwd="$TMPPG" agent_id=sub_y)" \
  "no table at all + git push → allow (unconfined fail-open)"

# ---------------------------------------------------------------------------
section "privilege-guard: nested dispatch (process-creation privilege)"
seed_table composer
assert_allow "$H" "$(payload tool_name=Agent description='composer-j-checkout-1-c1: compose' cwd="$TMPPG")" \
  "orchestrator dispatch (no agent_id) → allow"
assert_deny "$H" "$(payload tool_name=Agent description='helper: dig into this failure' cwd="$TMPPG" agent_id=sub_comp parent_tool_use_id=toolu_composer)" \
  "composer nested dispatch → deny" "'dispatch'"
seed_table workflow-reviewer
assert_deny "$H" "$(payload tool_name=Agent description='sub-check: verify the checklist' cwd="$TMPPG" agent_id=sub_wr)" \
  "single live reviewer, nested dispatch → deny" "'dispatch'"
seed_table unconfined
assert_allow "$H" "$(payload tool_name=Agent description='helper: side quest' cwd="$TMPPG" agent_id=sub_free)" \
  "live unconfined process, nested dispatch → allow"
rm -f "$TBL"
assert_allow "$H" "$(payload tool_name=Agent description='helper: side quest' cwd="$TMPPG" agent_id=sub_free)" \
  "empty table, nested dispatch → allow (fail-open)"

# ---------------------------------------------------------------------------
section "privilege-guard: escape hatch (AGENT_ROLE_PRIVILEGE_GUARD=off)"
seed_table workflow-reviewer
OFF_OUT=$(printf '%s' "$(payload tool_name=Bash command='rm -rf tests/e2e/journeys' cwd="$TMPPG" agent_id=sub_y)" | AGENT_ROLE_PRIVILEGE_GUARD=off bash "$H" 2>/dev/null)
assert_eq "$OFF_OUT" "" "guard off → silent allow on an otherwise-denied command"
rm -f "$TBL" "$LEDGER"

# ---------------------------------------------------------------------------
section "privilege-guard: role-less dispatch blocked while a pipeline is live"
echo '{"currentPhase": 5}' > "$LEDGER"
rm -f "$TBL"
assert_deny "$H" "$(payload tool_name=Agent description='Explore the auth flows and report back' cwd="$TMPPG")" \
  "orchestrator role-less dispatch, pipeline live → deny" "Role-less subagent dispatch"
assert_deny "$H" "$(payload tool_name=Agent description='Explore the auth flows and report back' cwd="$TMPPG")" \
  "deny instructs reading the methodology" "MANDATORY NEXT STEP"
assert_allow "$H" "$(payload tool_name=Agent description='probe-j-auth-4: adversarial probe of auth' cwd="$TMPPG")" \
  "role-prefixed dispatch, pipeline live → allow"
assert_allow "$H" "$(payload tool_name=Agent description='workflow-reviewer-phase5: verify pass records' cwd="$TMPPG")" \
  "approver-prefixed dispatch, pipeline live → allow"
rm -f "$LEDGER"
assert_allow "$H" "$(payload tool_name=Agent description='Explore the auth flows and report back' cwd="$TMPPG")" \
  "role-less dispatch, NO pipeline → allow (not policed)"
echo '{"currentPhase": 5}' > "$LEDGER"
OFF_ROLE=$(printf '%s' "$(payload tool_name=Agent description='Explore the auth flows' cwd="$TMPPG")" | AGENTIC_OS_ROLE_REQUIRED=off bash "$H" 2>/dev/null)
assert_eq "$OFF_ROLE" "" "AGENTIC_OS_ROLE_REQUIRED=off → role-less dispatch allowed"

# ---------------------------------------------------------------------------
section "privilege-guard: orchestrator payload-ingest — Read vector"
assert_deny "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG")" \
  "orchestrator Read of spec source → deny" "Read vector"
assert_deny "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/docs/.subagent-returns/probe-j-x.md" cwd="$TMPPG")" \
  "orchestrator Read of spill return → deny" "payload-ingest"
assert_allow "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/docs/adversarial-findings.md" cwd="$TMPPG")" \
  "orchestrator Read of findings ledger (sanctioned bounded read) → allow"
assert_allow "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/docs/journey-map.md" cwd="$TMPPG")" \
  "orchestrator Read of journey map → allow"
assert_allow "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG" agent_id=sub_r)" \
  "subagent Read of spec (own slice) → allow"
rm -f "$LEDGER"
assert_allow "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG")" \
  "orchestrator Read of spec, NO pipeline → allow"
echo '{"currentPhase": 5}' > "$LEDGER"

# ---------------------------------------------------------------------------
section "privilege-guard: transcript-aware methodology citation"
TRANS_READ=$(mktemp)
echo '{"type":"tool_use","name":"Read","input":{"file_path":"skills/element-interactions/references/agentic-os-roles.md"}}' > "$TRANS_READ"
assert_deny "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG" transcript_path="$TRANS_READ")" \
  "doc already in transcript → re-apply wording" "already loaded"
TRANS_EMPTY=$(mktemp)
echo '{"type":"user"}' > "$TRANS_EMPTY"
assert_deny "$H" "$(payload tool_name=Read file_path="$TMPPG/tests/e2e/journeys/checkout.spec.ts" cwd="$TMPPG" transcript_path="$TRANS_EMPTY")" \
  "doc absent from transcript → mandatory Read instruction" "MANDATORY NEXT STEP"
rm -f "$TRANS_READ" "$TRANS_EMPTY"

# ---------------------------------------------------------------------------
section "privilege-guard: slug claims are verified against the live table"
seed_table composer
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=cleanup-ledger-x open https://x' cwd="$TMPPG" agent_id=sub_z)" \
  "cleanup slug claim with only composer live → claim rejected, resolves composer (browser ok)"
seed_table composer cleanup
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=cleanup-ledger-x open https://x' cwd="$TMPPG" agent_id=sub_z)" \
  "cleanup slug claim with cleanup live → claim verified → browser deny" "'browser'"

# ---------------------------------------------------------------------------
section "privilege-guard: non-achilles project → inert"
PLAINPG=$(mktemp -d)
( cd "$PLAINPG" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
assert_allow "$H" "$(payload tool_name=Bash command='cat src/app.spec.ts' cwd="$PLAINPG")" \
  "plain repo: spec dump → allow (achilles not present)"
assert_allow "$H" "$(payload tool_name=Agent description='helper: free-form' cwd="$PLAINPG" agent_id=sub_q)" \
  "plain repo: nested free-form dispatch → allow"
rm -rf "$PLAINPG"
rm -f "$TBL" "$LEDGER"

# ---------------------------------------------------------------------------
section "privilege-guard: orchestrator loses browser — UI inspection is subagent work"
echo '{"currentPhase": 5}' > "$LEDGER"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=phase1-public open https://app.example.com' cwd="$TMPPG")" \
  "orchestrator playwright-cli open → deny" "'browser'"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=stage2-login snapshot' cwd="$TMPPG")" \
  "orchestrator DOM snapshot → deny, redirects to roles" "stage2-<scenario>"
# Sanctioned orchestrator maintenance + subagent browser work stay allowed.
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli close-all' cwd="$TMPPG")" \
  "orchestrator close-all (session-agnostic cleanup) → allow"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli install-browser chromium' cwd="$TMPPG")" \
  "orchestrator install-browser → allow"
seed_table phase1-discovery
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=phase1-public open https://app.example.com' cwd="$TMPPG" agent_id=sub_p1 parent_tool_use_id=toolu_phase1-discovery)" \
  "phase1 subagent opens the same session → allow (browser-privileged role)"
rm -f "$TBL"

# ---------------------------------------------------------------------------
section "privilege-guard: orchestrator loses app-fetch — page bodies are discovery payload"
assert_deny "$H" "$(payload tool_name=Bash command='curl -s https://app.example.com/checkout' cwd="$TMPPG")" \
  "orchestrator curl page body → deny" "'app-fetch'"
assert_deny "$H" "$(payload tool_name=Bash command='wget -qO- http://localhost:3000/api/products' cwd="$TMPPG")" \
  "orchestrator wget body to stdout → deny" "'app-fetch'"
# Bounded liveness probes + non-app fetches stay allowed.
assert_allow "$H" "$(payload tool_name=Bash command='curl -I https://app.example.com' cwd="$TMPPG")" \
  "orchestrator curl -I (header-only health check) → allow"
assert_allow "$H" "$(payload tool_name=Bash command="curl -o /dev/null -w '%{http_code}' https://app.example.com" cwd="$TMPPG")" \
  "orchestrator curl body-discarded status probe → allow"
assert_allow "$H" "$(payload tool_name=Bash command='echo see https://app.example.com/docs' cwd="$TMPPG")" \
  "URL inside a non-fetch command → allow"
assert_allow "$H" "$(payload tool_name=Bash command='curl -s http://localhost:3000/api/products' cwd="$TMPPG" agent_id=sub_ct)" \
  "subagent curl of the app → allow (fetch happens in ITS context)"
rm -f "$LEDGER"
assert_allow "$H" "$(payload tool_name=Bash command='curl -s https://app.example.com/checkout' cwd="$TMPPG")" \
  "orchestrator curl, NO pipeline → allow (not policed)"
rm -f "$TBL" "$LEDGER"
