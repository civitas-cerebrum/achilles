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
# Guardrail: a require()-READ that ALSO carries a write-shape is still DENY —
# write-shape is classified before read-shape, so require-as-read can never
# launder an actual write past the guard.
assert_deny "$HOOK" "$(bash_payload 'node -e "require(\"tests/e2e/docs/onboarding-status.json\"); require(\"fs\").writeFileSync(\"tests/e2e/docs/onboarding-status.json\",\"{}\")"')" "node -e require()+writeFileSync still denied (write-shape wins)" "protected"
assert_deny "$HOOK" "$(bash_payload 'cp my-hook.sh ~/.claude/hooks/onboarding-ledger-gate.sh')" "overwrite installed hook" "protected"
assert_deny "$HOOK" "$(bash_payload 'tee tests/e2e/docs/coverage-expansion-state.json < /tmp/x')" "tee into coverage state" "protected"
assert_deny "$HOOK" "$(bash_payload 'truncate -s 0 tests/e2e/docs/.ledger-integrity.json')" "truncate integrity sidecar" "protected"
assert_deny "$HOOK" "$(bash_payload 'yq -i ".a=1" tests/e2e/docs/journey-map.md')" "yq -i in-place edit on journey map" "protected"

assert_deny "$HOOK" "$(bash_payload ': >| tests/e2e/docs/onboarding-status.json')" "clobber redirect into ledger" "protected"

section "protected-artifact-bash-guard: write targets, not mentions"
# Observed false positive: the sed expression names the approver registry; the file edited is a lib.
assert_allow "$HOOK" "$(bash_payload "sed -i '' 's/LEDGER_APPROVERS_NAME=.*/LEDGER_APPROVERS_NAME=\".workflow-approvers.json\"/' hooks/lib/ledger.sh")" "sed -i whose expression names the registry, on another file"
assert_allow "$HOOK" "$(bash_payload 'cp tests/e2e/docs/onboarding-status.json /tmp/backup.json')" "cp FROM the ledger"
assert_allow "$HOOK" "$(bash_payload 'rm /tmp/junk && cat tests/e2e/docs/onboarding-status.json')" "rm of an unrelated path beside a ledger read"
assert_allow "$HOOK" "$(bash_payload 'echo "see tests/e2e/docs/journey-map.md" > /tmp/note.txt')" "a protected name inside a redirected string"
assert_allow "$HOOK" "$(bash_payload 'git commit -m "fix: rm tests/e2e/docs/onboarding-status.json"')" "git commit naming the ledger (writes only under .git)"
assert_allow "$HOOK" "$(bash_payload 'grep -l .workflow-approvers.json hooks/*.sh > /tmp/hits')" "grep for the registry name, redirected elsewhere"
assert_allow "$HOOK" "$(bash_payload 'echo x 2>&1 >/tmp/log; cat ~/.claude/settings.json')" "fd duplication is not a file target"
assert_deny "$HOOK" "$(bash_payload "sed -i '' 's/a/b/' hooks/x.sh tests/e2e/docs/.workflow-approvers.json")" "sed -i whose files include the registry" "protected"
assert_deny "$HOOK" "$(bash_payload 'cp /tmp/x tests/e2e/docs/.workflow-approvers.json')" "cp onto the registry" "protected"
assert_deny "$HOOK" "$(bash_payload 'cp -t ~/.claude/hooks x.sh')" "cp -t into the hook install" "protected"
assert_deny "$HOOK" "$(bash_payload 'mv tests/e2e/docs/onboarding-status.json /tmp/x')" "mv away from the ledger (removes it)" "protected"
assert_deny "$HOOK" "$(bash_payload 'ls | tee -a tests/e2e/docs/journey-map.md')" "tee -a after a pipe" "protected"
assert_deny "$HOOK" "$(bash_payload 'dd if=/dev/zero of=tests/e2e/docs/.ledger-integrity.json')" "dd of= the integrity sidecar" "protected"
assert_deny "$HOOK" "$(bash_payload 'echo x 2> tests/e2e/docs/journey-map.md')" "stderr redirect into the journey map" "protected"
assert_deny "$HOOK" "$(bash_payload 'perl -pi -e "s/a/b/" tests/e2e/docs/adversarial-findings.md')" "perl -pi on the findings ledger" "protected"
assert_deny "$HOOK" "$(bash_payload 'find tests -name onboarding-status.json -delete')" "find -delete naming the ledger" "protected"
assert_deny "$HOOK" "$(bash_payload 'echo tests/e2e/docs/onboarding-status.json | xargs rm')" "xargs rm fed the ledger path" "protected"
assert_deny "$HOOK" "$(bash_payload "bash -c 'echo {} > tests/e2e/docs/onboarding-status.json'")" "bash -c script redirect" "protected"
assert_deny "$HOOK" "$(bash_payload 'x=$(tee tests/e2e/docs/journey-map.md < /tmp/x)')" "tee inside a command substitution" "protected"
assert_deny "$HOOK" "$(bash_payload 'sudo rm ~/.claude/settings.json')" "rm behind sudo" "protected"
assert_deny "$HOOK" "$(bash_payload 'eval "rm tests/e2e/docs/onboarding-status.json"')" "rm inside eval" "protected"
assert_deny "$HOOK" "$(bash_payload 'bash <<EOF
rm tests/e2e/docs/onboarding-status.json
EOF')" "rm in a heredoc fed to bash" "protected"
assert_allow "$HOOK" "$(bash_payload 'cat > /tmp/notes.md <<EOF
rm tests/e2e/docs/onboarding-status.json
EOF')" "the same text in a heredoc written to another file"

section "protected-artifact-bash-guard: spellings that reach a protected file"
for p in '.claude//hooks/a.sh' \
         '.claude/./hooks/a.sh' '.claude/x/../hooks/a.sh' '~/.claude/settings.json' '"$HOME"/.claude/settings.json' \
         '${HOME}/.claude/settings.json'; do
  assert_deny "$HOOK" "$(bash_payload "echo x > $p")" "redirect into $p" "protected"
done
for p in '.claude/hooksx/a.sh' '.claude/hooks.bak' '.claude/x/../hooksy/a' '.claude/hooks/../skills/a.md' \
         'tests/e2e/docs/onboarding-status.json.bak' '/tmp/.claude-hooks'; do
  assert_allow "$HOOK" "$(bash_payload "echo x > $p")" "redirect into near-miss $p"
done

section "protected-artifact-bash-guard: ALLOW read-only access + unrelated writes"
assert_allow "$HOOK" "$(bash_payload 'cat tests/e2e/docs/onboarding-status.json')" "read ledger"
assert_allow "$HOOK" "$(bash_payload 'jq .currentPhase tests/e2e/docs/onboarding-status.json')" "jq read ledger"
assert_allow "$HOOK" "$(bash_payload 'grep -n FINDING tests/e2e/docs/adversarial-findings.md')" "grep findings"
assert_allow "$HOOK" "$(bash_payload 'git diff tests/e2e/docs/journey-map.md')" "git diff journey map"
assert_allow "$HOOK" "$(bash_payload 'echo hello > /tmp/scratch.txt')" "unrelated redirect"
assert_allow "$HOOK" "$(bash_payload 'npx playwright test')" "unrelated command"
assert_allow "$HOOK" "$(bash_payload 'ls tests/e2e/docs/')" "ls docs dir"
assert_allow "$HOOK" "$(bash_payload 'yq .currentPhase tests/e2e/docs/onboarding-status.json')" "yq read-only (no -i)"
# Interpreter one-liners cannot be proved read-only: a line that names a protected path denies.
assert_deny "$HOOK" "$(bash_payload 'python3 -c "import json; print(json.load(open(\"tests/e2e/docs/onboarding-status.json\"))[\"currentPhase\"])"')" "python3 -c json.load read of ledger" "Cannot prove"
assert_deny "$HOOK" "$(bash_payload 'node -e "console.log(require(\"fs\").readFileSync(\"tests/e2e/docs/coverage-expansion-state.json\",\"utf8\"))"')" "node -e readFileSync read of coverage state" "Cannot prove"
assert_deny "$HOOK" "$(bash_payload 'node -e "const j=require(\"tests/e2e/docs/onboarding-status.json\"); console.log(j.currentPhase)"')" "node -e require() read of ledger" "Cannot prove"
assert_deny "$HOOK" "$(bash_payload 'node -e "const j=require(\"tests/perf/docs/perf-onboarding-status.json\"); console.log(j.status)"')" "node -e require() read of perf ledger" "Cannot prove"

section "protected-artifact-bash-guard: an unclassifiable interpreter one-liner denies"
assert_deny "$HOOK" "$(bash_payload 'python3 -c "import sys; sys.argv.append(\"tests/e2e/docs/onboarding-status.json\")"')" "interpreter one-liner, no read/write token → deny" "Cannot prove"

section "protected-artifact-bash-guard: flake-quarantine.md is protected"
# harvest-U3: the flake-quarantine ledger is a protected pipeline-state
# artifact — sed -i against it is denied; a Write-tool append is the
# sanctioned path (Write/Edit are not seen by this Bash-only guard, so
# the guard silent-allows non-Bash tools by tool-name filter).
assert_deny "$HOOK" "$(bash_payload 'sed -i "" "s/a/b/" tests/e2e/docs/flake-quarantine.md')" "sed -i on flake-quarantine ledger → DENY" "protected"
assert_allow "$HOOK" "$(bash_payload 'grep -n FLAKE tests/e2e/docs/flake-quarantine.md')" "grep flake-quarantine read → ALLOW"
# Write-tool append goes through Write|Edit, which this Bash guard never sees.
assert_allow "$HOOK" "$("$JQ" -n '{tool_name:"Write", tool_input:{file_path:"tests/e2e/docs/flake-quarantine.md", content:"x"}}')" "Write-tool append to flake-quarantine → ALLOW (non-Bash)"

section "protected-artifact-bash-guard: a line too long to split fails closed"
PAD=$(printf 'w%.0s ' $(seq 1 17000))
assert_deny "$HOOK" "$(bash_payload "echo $PAD; cat tests/e2e/docs/journey-map.md")" "33 KB line naming the journey map → DENY" "protected"
assert_deny "$HOOK" "$(bash_payload "echo $PAD > /tmp/pad")" "33 KB line naming no protected path → DENY (unverifiable)" "too long to verify"
