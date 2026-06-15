#!/bin/bash
# Tests for protected-artifact-bash-guard.sh
HOOK="$HOOK_DIR/protected-artifact-bash-guard.sh"

bash_payload() { "$JQ" -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

section "protected-artifact-bash-guard: DENY write-shaped constructs touching protected artifacts"
assert_deny "$HOOK" "$(bash_payload 'cat > tests/e2e/docs/onboarding-status.json <<EOF
{}
EOF')" "heredoc redirect into ledger" "protected"
assert_deny "$HOOK" "$(bash_payload 'echo x >> tests/e2e/docs/journey-map.md')" "append redirect into journey map" "protected"
assert_deny "$HOOK" "$(bash_payload 'rm tests/e2e/docs/onboarding-status.json')" "rm ledger (reset trick)" "protected"
assert_deny "$HOOK" "$(bash_payload 'jq . x.json > tests/e2e/docs/.workflow-approvers.json')" "jq redirect into approver registry" "protected"
assert_deny "$HOOK" "$(bash_payload 'sed -i "" "s/a/b/" tests/e2e/docs/adversarial-findings.md')" "sed -i on findings ledger" "protected"
assert_deny "$HOOK" "$(bash_payload 'mv /tmp/forged.json tests/e2e/docs/.phase4-cycle-state.json')" "mv onto cycle state" "protected"
assert_deny "$HOOK" "$(bash_payload 'python3 -c "open(\"tests/e2e/docs/onboarding-status.json\",\"w\").write(\"{}\")"')" "python -c mentioning ledger" "protected"
assert_deny "$HOOK" "$(bash_payload 'node -e "require(\"fs\").writeFileSync(process.env.HOME+\"/.claude/settings.json\",\"{}\")"')" "node -e touching settings.json" "protected"
assert_deny "$HOOK" "$(bash_payload 'cp my-hook.sh ~/.claude/hooks/onboarding-ledger-gate.sh')" "overwrite installed hook" "protected"
assert_deny "$HOOK" "$(bash_payload 'tee tests/e2e/docs/coverage-expansion-state.json < /tmp/x')" "tee into coverage state" "protected"
assert_deny "$HOOK" "$(bash_payload 'truncate -s 0 tests/e2e/docs/.ledger-integrity.json')" "truncate integrity sidecar" "protected"
assert_deny "$HOOK" "$(bash_payload 'yq -i ".a=1" tests/e2e/docs/journey-map.md')" "yq -i in-place edit on journey map" "protected"

assert_deny "$HOOK" "$(bash_payload ': >| tests/e2e/docs/onboarding-status.json')" "clobber redirect into ledger" "protected"
# Pin the documented false-positive tradeoff: cp is a read-only use of the protected file,
# but the guard denies it anyway because a mutate verb co-occurs with a protected name.
# DO NOT 'fix' this — it is an accepted over-deny by design (see header comment).
assert_deny "$HOOK" "$(bash_payload 'cp tests/e2e/docs/onboarding-status.json /tmp/backup.json')" "accepted false positive: read-only cp of protected file (intentional over-deny)" "protected"

section "protected-artifact-bash-guard: ALLOW read-only access + unrelated writes"
assert_allow "$HOOK" "$(bash_payload 'cat tests/e2e/docs/onboarding-status.json')" "read ledger"
assert_allow "$HOOK" "$(bash_payload 'jq .currentPhase tests/e2e/docs/onboarding-status.json')" "jq read ledger"
assert_allow "$HOOK" "$(bash_payload 'grep -n FINDING tests/e2e/docs/adversarial-findings.md')" "grep findings"
assert_allow "$HOOK" "$(bash_payload 'git diff tests/e2e/docs/journey-map.md')" "git diff journey map"
assert_allow "$HOOK" "$(bash_payload 'echo hello > /tmp/scratch.txt')" "unrelated redirect"
assert_allow "$HOOK" "$(bash_payload 'npx playwright test')" "unrelated command"
assert_allow "$HOOK" "$(bash_payload 'ls tests/e2e/docs/')" "ls docs dir"
assert_allow "$HOOK" "$(bash_payload 'yq .currentPhase tests/e2e/docs/onboarding-status.json')" "yq read-only (no -i)"
# Interpreter one-liner READS of a protected artifact must ALLOW — the
# prior unconditional INTERP_HIT denied these. (Allow-test convention:
# the read-only adjacents to the write-shaped python/node denies above.)
assert_allow "$HOOK" "$(bash_payload 'python3 -c "import json; print(json.load(open(\"tests/e2e/docs/onboarding-status.json\"))[\"currentPhase\"])"')" "python3 -c json.load read of ledger"
assert_allow "$HOOK" "$(bash_payload 'node -e "console.log(require(\"fs\").readFileSync(\"tests/e2e/docs/coverage-expansion-state.json\",\"utf8\"))"')" "node -e readFileSync read of coverage state"

section "protected-artifact-bash-guard: ambiguous interpreter one-liner → ASK"
# Interpreter one-liner mentioning a protected path with NO recognizable
# read or write token — can't classify, so defer to the operator.
assert_ask "$HOOK" "$(bash_payload 'python3 -c "import sys; sys.argv.append(\"tests/e2e/docs/onboarding-status.json\")"')" "interpreter one-liner, no read/write token → ask" "ASK"

section "protected-artifact-bash-guard: flake-quarantine.md is protected"
# harvest-U3: the flake-quarantine ledger is a protected pipeline-state
# artifact — sed -i against it is denied; a Write-tool append is the
# sanctioned path (Write/Edit are not seen by this Bash-only guard, so
# the guard silent-allows non-Bash tools by tool-name filter).
assert_deny "$HOOK" "$(bash_payload 'sed -i "" "s/a/b/" tests/e2e/docs/flake-quarantine.md')" "sed -i on flake-quarantine ledger → DENY" "protected"
assert_allow "$HOOK" "$(bash_payload 'grep -n FLAKE tests/e2e/docs/flake-quarantine.md')" "grep flake-quarantine read → ALLOW"
# Write-tool append goes through Write|Edit, which this Bash guard never sees.
assert_allow "$HOOK" "$("$JQ" -n '{tool_name:"Write", tool_input:{file_path:"tests/e2e/docs/flake-quarantine.md", content:"x"}}')" "Write-tool append to flake-quarantine → ALLOW (non-Bash)"
