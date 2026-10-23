#!/bin/bash
# Tests for pr-attribution-gate.sh — denies PRs carrying AI-attribution metadata.
H="$HOOK_DIR/pr-attribution-gate.sh"

section "pr-attribution-gate: tool-name / trigger filtering"
assert_allow "$H" "$(payload tool_name=Read file_path=/tmp/x)" "Read tool → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='ls -la')" "non-gh bash → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='gh pr list')" "gh pr list → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='gh pr view 42')" "gh pr view → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='gh pr checkout 42')" "gh pr checkout → silent allow"
# A commit carrying attribution is commit-message-gate's job, not this hook's.
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'x' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'")" \
  "git commit (other gate's surface) → silent allow"

section "pr-attribution-gate: well-formed PRs are silent allow"
assert_allow "$H" "$(payload tool_name=Bash command="gh pr create --title 'test(j-checkout): lock CSRF fix' --body 'Adds a regression test for the CSRF fix.'")" \
  "plain PR (no attribution) → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="gh pr edit 42 --body 'Updated the rollout notes.'")" \
  "gh pr edit without attribution → ALLOW"
# A human co-author trailer is legitimate and must not trip the gate.
assert_allow "$H" "$(payload tool_name=Bash command="gh pr create --title 'fix: pair work' --body 'Co-Authored-By: Jane Doe <jane@example.com>'")" \
  "Co-Authored-By: Jane Doe (human) → ALLOW"
# A prose mention of the word "claude" is not attribution.
assert_allow "$H" "$(payload tool_name=Bash command="gh pr create --title 'docs: fix typo' --body 'Corrects the spelling of claude in the glossary.'")" \
  "prose mention of claude → ALLOW"

section "pr-attribution-gate: AI-attribution DENY (full-surface scan)"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr create --title 'test(j-x): fix' --body 'Body text

Co-Authored-By: Claude <noreply@anthropic.com>'")" \
  "gh pr create with Co-Authored-By: Claude → DENY" "AI-attribution"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr create --title 'x' --body 'Body

Generated with [Claude Code](https://claude.com/claude-code)'")" \
  "Generated with [Claude Code] marker → DENY" "AI-attribution"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr create --title 'x' --body 'See https://claude.ai/code for details'")" \
  "claude.ai/code URL → DENY" "AI-attribution"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr edit 42 --body 'Revised

Co-Authored-By: Claude Opus <noreply@anthropic.com>'")" \
  "gh pr edit with attribution → DENY" "AI-attribution"
assert_deny "$H" "$(payload tool_name=Bash command="command gh pr create --title 'x' --body 'Co-Authored-By: Claude <noreply@anthropic.com>'")" \
  "command-wrapped gh pr create → DENY" "AI-attribution"

section "pr-attribution-gate: --body-file / -F contents are scanned"
# A body written to a file first must be checked the same as an inline --body.
BODYFILE_68=$(mktemp /tmp/pr-attrib-gate-XXXXXX)
printf 'Adds the regression test.\n\nGenerated with [Claude Code](https://claude.com/claude-code)\n' > "$BODYFILE_68"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr create --title 'test(j-x): fix' --body-file $BODYFILE_68")" \
  "--body-file with attribution inside → DENY" "AI-attribution"
assert_deny "$H" "$(payload tool_name=Bash command="gh pr create --title 'test(j-x): fix' -F $BODYFILE_68")" \
  "-F <file> with attribution inside → DENY" "AI-attribution"
# A clean body file must still pass.
CLEANFILE_68=$(mktemp /tmp/pr-clean-gate-XXXXXX)
printf 'Adds the regression test for the CSRF fix.\n' > "$CLEANFILE_68"
assert_allow "$H" "$(payload tool_name=Bash command="gh pr create --title 'test(j-x): fix' --body-file $CLEANFILE_68")" \
  "--body-file without attribution → ALLOW"
# A missing file must not crash the gate (fail-open on unresolvable path).
assert_allow "$H" "$(payload tool_name=Bash command="gh pr create --title 'x' --body-file /tmp/does-not-exist-68")" \
  "unresolvable --body-file → ALLOW (no crash)"
rm -f "$BODYFILE_68" "$CLEANFILE_68"
