#!/bin/bash
# Tests for commit-message-gate.sh — per-phase / per-journey commit-convention enforcer.
H="$HOOK_DIR/commit-message-gate.sh"

section "commit-message-gate: well-formed messages are silent allow"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-checkout): cycle-2 — multi-item variant'")" "test(j-...) → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'docs(ledger): j-checkout — 4 probes recorded'")" "docs(ledger): j-... → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-checkout-regression): lock CSRF fix'")" "test(j-...-regression) → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'docs: journey map — 12 journeys prioritized'")" "docs: journey map → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'chore: scaffold element-interactions framework'")" "chore: scaffold → ALLOW"

section "commit-message-gate: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Read file_path=/tmp/x)" "Read tool → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='ls -la')" "non-commit bash → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='git status')" "git status → silent allow"

section "commit-message-gate: --no-verify / --no-gpg-sign DENY"
assert_deny "$H" "$(payload tool_name=Bash command="git commit --no-verify -m 'test(j-x): fix'")" "--no-verify → DENY" "bypass hooks or signing"
assert_deny "$H" "$(payload tool_name=Bash command="git commit --no-gpg-sign -m 'test(j-x): fix'")" "--no-gpg-sign → DENY" "bypass hooks or signing"
# The trigger regex now tolerates `-c key=val` global flags and command/env
# wrappers between `git` and `commit`, so `git -c <k>=<v> commit` is gated.
assert_deny "$H" "$(payload tool_name=Bash command="git -c commit.gpgsign=false commit -m 'test(j-x): fix'")" "git -c form bypass → DENY" "bypass hooks or signing"
assert_deny "$H" "$(payload tool_name=Bash command="command git commit --no-verify -m 'test(j-x): fix'")" "command-wrapped --no-verify → DENY" "bypass hooks or signing"

section "commit-message-gate: --no-verify inside message body is allowed"
# Quoted-message false-positive avoidance — the flag appears only as message content.
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'docs(hooks): blocks --no-verify and --no-gpg-sign'")" "flag inside message body → ALLOW"

section "commit-message-gate: multi-journey commit DENY"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-checkout, j-signup): cycle-2 batch'")" "multi-journey scope → DENY" "Multi-journey commit"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-a,j-b): combined'")" "comma-joined multi-j → DENY" "Multi-journey commit"

section "commit-message-gate: feat(e2e) / feat(test) / feat(coverage) DENY"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'feat(e2e): add checkout coverage'")" "feat(e2e) → DENY" "'test:' not 'feat:'"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'feat(test): new spec'")" "feat(test) → DENY" "'test:' not 'feat:'"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'feat(coverage): expand suite'")" "feat(coverage) → DENY" "'test:' not 'feat:'"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'feat(onboarding): new flow'")" "feat(onboarding) → DENY" "'test:' not 'feat:'"

section "commit-message-gate: review(...) commits DENY"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'review(j-checkout): findings'")" "review(...) → DENY" "Review-tagged commits are forbidden"

section "commit-message-gate: --message= / -F <file> extraction + heredoc fallback"
# --message=<msg> form carries the same banned patterns as -m.
assert_deny "$H" "$(payload tool_name=Bash command="git commit --message='review(j-checkout): findings'")" \
  "--message= with review(...) → DENY" "Review-tagged commits are forbidden"
# -F <path>: the gate reads the message from the file when it exists.
MSGFILE_42=$(mktemp /tmp/commit-msg-gate-XXXXXX)
printf 'review(j-checkout): findings from pass 2\n' > "$MSGFILE_42"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -F $MSGFILE_42")" \
  "-F <file> with banned message inside the file → DENY" "Review-tagged commits are forbidden"
rm -f "$MSGFILE_42"
# Unparseable message source (heredoc via -F -): deny only when the raw
# command string matches the banned patterns — a clean heredoc message allows.
HEREDOC_CLEAN_42='git commit -F - <<EOF
test(j-checkout): cycle-2 — multi-item variant
EOF'
assert_allow "$H" "$(payload tool_name=Bash command="$HEREDOC_CLEAN_42")" \
  "heredoc commit with clean message → ALLOW"

section "commit-message-gate: AI-attribution DENY (full-surface scan)"
# A second -m trailer carrying a Co-Authored-By: Claude line → DENY. The
# attribution scan reads the FULL command, not just the first -m subject.
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-x): fix login' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'")" \
  "second -m trailer with Co-Authored-By: Claude → DENY" "AI-attribution"
# Heredoc body carrying the 'Generated with [Claude Code]' marker → DENY.
HEREDOC_ATTRIB_42='git commit -F - <<EOF
test(j-x): fix login

🤖 Generated with [Claude Code](https://claude.ai/code)
EOF'
assert_deny "$H" "$(payload tool_name=Bash command="$HEREDOC_ATTRIB_42")" \
  "heredoc body with Generated with [Claude Code] → DENY" "AI-attribution"
# claude.ai/code URL anywhere on the command surface → DENY.
assert_deny "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-x): fix' -m 'see https://claude.ai/code'")" \
  "claude.ai/code URL → DENY" "AI-attribution"
# -F <file> whose contents carry a Co-Authored-By: Claude trailer → DENY.
ATTRIBFILE_42=$(mktemp /tmp/commit-attrib-gate-XXXXXX)
printf 'test(j-x): fix login\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$ATTRIBFILE_42"
assert_deny "$H" "$(payload tool_name=Bash command="git commit -F $ATTRIBFILE_42")" \
  "-F <file> with Co-Authored-By: Claude inside → DENY" "AI-attribution"
rm -f "$ATTRIBFILE_42"

section "commit-message-gate: AI-attribution ALLOW (adjacent realistic traffic)"
# A normal conventional commit with no attribution → ALLOW.
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-login): cycle-1 — happy path'")" \
  "plain conventional commit (no attribution) → ALLOW"
# A human co-author (non-AI identity) is legitimate → ALLOW. The trailer
# rule targets AI identities, not pair-programming credit.
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'test(j-x): pair fix' -m 'Co-Authored-By: Jane Doe <jane@example.com>'")" \
  "Co-Authored-By: Jane Doe (human) → ALLOW"
# A commit whose subject merely QUOTES the word 'claude' in prose (e.g.
# fixing a typo) must still ALLOW — the scan targets attribution
# trailers/markers, not any mention.
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'docs: fix typo — spell claude correctly in the changelog'")" \
  "prose mention of 'claude' (typo fix) → ALLOW"
