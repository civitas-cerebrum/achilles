#!/bin/bash
# commit-message-gate.sh — per-phase / per-journey commit-convention enforcer
#
# Hook    : PreToolUse:Bash  (filters to `git commit` invocations only)
# Mode    : DENY (high-confidence anti-patterns) — no WARN path
# State   : none
# Env     : none
#
# Rule
# ----
# `git commit` invocations during coverage-expansion / journey-mapping work
# must follow the conventions documented in
#   skills/coverage-expansion/SKILL.md §"Commit-message conventions"
#
# This gate enforces only the most common anti-patterns (coverage expansion
# is never `feat`; multi-journey commits are forbidden; hook bypass is
# forbidden; spec-file commits need a subject scope). Detail-level
# validation is intentionally out of scope — it would be brittle.
#
# Why
# ---
# The git log has to be filterable by `<j-slug>` and pass kind. A multi-
# journey commit destroys that filterability; a `feat(e2e):` commit
# misclassifies coverage growth as a feature. Hook bypass (`--no-verify`,
# `--no-gpg-sign`) is the meta-failure that defeats the rest of the gate
# suite.
#
# Canonical reference
# -------------------
# skills/coverage-expansion/SKILL.md §"Commit-message conventions"
# (Convention reproduced in the comment block below for at-a-glance
#  scanning; the SKILL.md section is canonical.)
#
# Conventions
# -----------
#   chore: scaffold element-interactions framework
#   docs: initial app-context and site map
#   test: happy path — <name>
#   docs: journey map — <N> journeys prioritized
#   test(j-<slug>): <variant>                 [compositional pass 1-3]
#   docs(ledger): j-<slug> — N probes, ...    [adversarial pass 4]
#   test(j-<slug>-regression): lock <desc>    [adversarial pass 5]
#   docs(ledger): dedupe cross-cutting findings
#   docs(coverage-expansion-state): ...
#   chore: ...                                [infrastructure]
#
# AI-attribution rule
# -------------------
# Commits must NOT carry AI-attribution metadata. A `Co-Authored-By:`
# trailer naming claude / anthropic / noreply@anthropic.com, a "Generated
# with [Claude Code]" marker, or a claude.ai/code URL → DENY. This scans
# the FULL command surface plus any `-F` file contents independently of
# the `-m` subject extraction, so a second `-m` trailer, a heredoc body,
# or a message file all get caught.
#
# Canonical reference: contributing/SKILL.md §"AI assistants don't get
# Co-Authored-By trailers". The upstream fix when this fires is to remove
# the trailer instruction from CLAUDE.md (do not re-add it per-commit).
#
# Failure → action
# ----------------
# - `feat(e2e):` or `feat(test):` style                        → DENY
# - Multi-journey scope `test(j-a,j-b,...):`                   → DENY
# - `--no-verify` / `--no-gpg-sign` flags                      → DENY (hook bypass)
# - AI-attribution trailer / marker / claude.ai/code URL       → DENY
# - `test:` with no scope on a commit that touches a spec file → DENY
# - `review(...)` or any review-tagged commit                  → DENY (Stage B never commits)
# - Anything else                                              → silent allow

set -euo pipefail

# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH. Reinstall the package or install jq manually." >&2
  exit 1
fi

# --- helpers ---
emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# --- input ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""')

# Only fire on git commit invocations. The trigger tolerates `command` /
# `env` wrappers and `-c key=val` / `--long[=val]` global flags between
# `git` and `commit`, so wrapped invocations like `git -c user.name=x
# commit` and `command git commit` are gated.
GIT_COMMIT_TRIGGER='(^|[;&|][[:space:]]*)((command|env)[[:space:]]+)?git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+commit([[:space:]]|$)'
if ! echo "$CMD" | grep -qE "$GIT_COMMIT_TRIGGER"; then
  exit 0
fi

# Strip quoted substrings from the command before scanning for bypass flags.
# Otherwise a commit *message* that documents these flags (e.g.
# `-m "blocks --no-verify"`) would false-positive — the flags must be detected
# only when they appear as actual git arguments, not as message content.
# Replace single- and double-quoted regions with placeholders.
CMD_NO_QUOTES=$(echo "$CMD" | python3 -c "
import sys, re
s = sys.stdin.read()
# Remove double-quoted strings (with possible escaped quotes inside).
s = re.sub(r'\"(?:[^\"\\\\]|\\\\.)*\"', '\"___MSG___\"', s)
# Remove single-quoted strings.
s = re.sub(r\"'(?:[^'\\\\]|\\\\.)*'\", \"'___MSG___'\", s)
# Remove backtick-quoted command substitutions.
s = re.sub(r'\`(?:[^\`\\\\]|\\\\.)*\`', '\`___SUBST___\`', s)
# Remove \$(...) command substitutions (non-greedy, single level).
s = re.sub(r'\\\$\\([^)]*\\)', '\\\$(___SUBST___)', s)
sys.stdout.write(s)
" 2>/dev/null || echo "$CMD")

# Anti-pattern: --no-verify / --no-gpg-sign / -c commit.gpgsign=false as args
if echo "$CMD_NO_QUOTES" | grep -qE '(^|[[:space:]])(--no-verify|--no-gpg-sign|commit\.gpgsign=false)([[:space:]]|$)'; then
  emit_deny "[BLOCKED] git commit cannot bypass hooks or signing.

Command contains one of: --no-verify, --no-gpg-sign, commit.gpgsign=false (as a git argument, not as message content).

Fix: investigate the underlying issue and address it. Hooks exist to catch real problems (failing tests, lint violations, sentinel-stripping); bypassing them creates silent breakage downstream. See skills/coverage-expansion/SKILL.md and the harness's own rule: \"Never skip hooks (--no-verify) or bypass signing unless the user has explicitly asked for it. If a hook fails, investigate and fix the underlying issue.\""
  exit 0
fi

# --- AI-attribution scan (full-surface, independent of -m extraction) ---
# Scans the ENTIRE command string plus the contents of every resolvable
# `-F <file>` / `--file <file>` argument. This is deliberately independent
# of the single-subject `-m` extraction below: a second `-m` trailer, a
# heredoc body, a message file, or a `--message=` body all land in
# ATTRIB_SCAN and get checked. The match targets attribution TRAILERS and
# MARKERS specifically (a Co-Authored-By: line naming an AI identity, a
# "Generated with [Claude Code]" marker, or a claude.ai/code URL) — NOT
# any prose mention of the word "claude", so a commit fixing a typo that
# quotes "claude" in its subject still ALLOWs.
ATTRIB_SCAN="$CMD"
# Resolve EVERY -F / --file argument's contents and append them.
ATTRIB_FILES=$(echo "$CMD" | grep -oE -- "(-F|--file)[[:space:]=][[:space:]]*[^[:space:]]+" \
  | sed -E "s/^(-F|--file)[[:space:]=][[:space:]]*//;s/^['\"]//;s/['\"]\$//" || true)
if [ -n "$ATTRIB_FILES" ]; then
  while IFS= read -r af; do
    [ -z "$af" ] && continue
    [ "$af" = "-" ] && continue
    if [ -f "$af" ]; then
      ATTRIB_SCAN="${ATTRIB_SCAN}
$(cat "$af" 2>/dev/null || true)"
    fi
  done <<EOF
$ATTRIB_FILES
EOF
fi

# The co-authored-by alternative matches the trailer at a line start OR
# immediately after a quote (covers a second inline `-m 'Co-Authored-By:
# …'` trailer where the whole git command is a single line). The
# generated-with / claude.ai-code alternatives are markers/URLs that are
# never legitimate in a commit message, so they match anywhere.
if echo "$ATTRIB_SCAN" | grep -qiE '(^|['"'"'"])[[:space:]]*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude([[:space:]]+code)?\b|claude\.ai/code'; then
  emit_deny "[BLOCKED] git commit carries AI-attribution metadata.

Command/message surface contains one of:
  - a \`Co-Authored-By:\` trailer naming claude / anthropic / noreply@anthropic.com
  - a \"Generated with [Claude Code]\" marker
  - a claude.ai/code URL

These artifacts must not enter the git history. Per contributing/SKILL.md
§\"AI assistants don't get Co-Authored-By trailers\", AI tooling is not a
co-author and commits should not advertise the tool that produced them.

Fix: re-author the commit message WITHOUT the attribution trailer / marker /
URL. The upstream fix is to remove the trailer instruction from CLAUDE.md so
it stops being added in the first place (do not re-append it per commit)."
  exit 0
fi

# Extract the commit message. Recognised sources, in order:
#   -m "..." / -m '...'            (first -m flag)
#   --message="..." / --message='...'
#   -F <path> / --file <path>      (message read from the file when it exists)
MSG=$(echo "$CMD" | grep -oE -- "-m[[:space:]]*['\"][^'\"]+['\"]" | head -1 | sed -E "s/^-m[[:space:]]*['\"]//;s/['\"]$//" || true)
if [ -z "$MSG" ]; then
  MSG=$(echo "$CMD" | grep -oE -- "--message=['\"][^'\"]+['\"]" | head -1 | sed -E "s/^--message=['\"]//;s/['\"]$//" || true)
fi
if [ -z "$MSG" ]; then
  MSG_FILE=$(echo "$CMD" | grep -oE -- "(-F|--file)[[:space:]=][[:space:]]*[^[:space:]]+" | head -1 \
    | sed -E "s/^(-F|--file)[[:space:]=][[:space:]]*//;s/^['\"]//;s/['\"]$//" || true)
  if [ -n "$MSG_FILE" ] && [ "$MSG_FILE" != "-" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE" 2>/dev/null || true)
  fi
fi

# When the message source is unparseable (heredoc via `-F -`, command
# substitution, an editor-composed message, …) fall back to scanning the
# RAW command string: deny only when a banned pattern appears verbatim
# there; otherwise allow. Never deny blind on extraction failure.
SCAN="$MSG"
if [ -z "$SCAN" ]; then
  SCAN="$CMD"
fi

# Anti-pattern: multi-journey commit shape  test(j-a,j-b,...): ...
if echo "$SCAN" | grep -qE 'test\([^)]*j-[a-z0-9-]+[[:space:]]*,'; then
  emit_deny "[BLOCKED] Multi-journey commit detected.

Message: \"${SCAN}\"

Fix: split into one commit per journey. The convention from coverage-expansion §\"Commit-message conventions\" is one journey per commit, no exceptions:

  test(j-checkout): cycle-2 — multi-item variant
  test(j-signup): cycle-2 — long-input edge

Why: per-journey commits make the git log filterable by j-<slug>. A multi-journey commit hides which journey a regression came from when bisecting."
  exit 0
fi

# Anti-pattern: feat(e2e): ... — coverage expansion / e2e tests are never `feat`.
if echo "$SCAN" | grep -qiE '^feat\((e2e|tests|test|coverage|journey|onboarding)\)'; then
  emit_deny "[BLOCKED] Test/coverage commits are 'test:' not 'feat:'.

Message: \"${SCAN}\"

Fix: use the convention from coverage-expansion §\"Commit-message conventions\":

  test(<j-slug>): <variant>          for compositional passes
  docs(ledger): <j-slug> — ...       for adversarial pass 4
  test(<j-slug>-regression): ...     for adversarial pass 5
  docs(ledger): dedupe ...           for cleanup

Why: the convention makes commits filterable by type. 'feat(...)' is for product features."
  exit 0
fi

# Anti-pattern: review(...) or any review-tagged commit — Stage B never
# commits per coverage-expansion/SKILL.md §"Commit-message conventions"
# and §"Dual-stage per-pass contract". Reviewer judgements live in the
# state file, not the git log.
if echo "$SCAN" | grep -qiE '^review\('; then
  emit_deny "[BLOCKED] Review-tagged commits are forbidden.

Message: \"${SCAN}\"

Fix: Stage B reviewer judgements go in the state file's per-journey \`review_status\` and \`final_must_fix\` fields, never as commits. The git log records what landed (Stage A's tests, ledger entries, regression locks) — not the review trail.

If you intended a tests-from-Stage-A commit, the right form is:

  test(<j-slug>): <variant>          for compositional passes
  docs(ledger): <j-slug> — ...       for adversarial pass 4
  test(<j-slug>-regression): ...     for adversarial pass 5

See coverage-expansion §\"Commit-message conventions\"."
  exit 0
fi

# Anti-pattern: fix(...) for a new test file (commits adding spec files should
# be `test(...)` per the convention; `fix(...)` is reserved for fixing existing
# code/tests).
# This is a soft check — we can't easily tell if files are new vs modified
# without reading the index. Leave as a doc-level rule for now.

exit 0
