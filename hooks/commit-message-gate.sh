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
#   skills/coverage-expansion/references/depth-mode-pipeline.md §"Commit-message conventions"
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
# skills/coverage-expansion/references/depth-mode-pipeline.md §"Commit-message conventions"
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
# Canonical reference: contributing-to-achilles-protocol/SKILL.md §"AI assistants don't get
# Co-Authored-By: trailers". The upstream fix when this fires is to remove
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

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/coverage-expansion/references/depth-mode-pipeline.md §\"Commit-message conventions\"\n  skills/contributing-to-achilles-protocol/SKILL.md §\"AI assistants don't get Co-Authored-By trailers\""


# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib hook-emit.sh shell-words.sh
hook_jq_init fatal

# --- input ---
hook_read_input

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
hook_lib achilles-activation.sh
achilles_require_active "$INPUT"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""')

# Only fire on git commit, judged on the words the shell runs (lib/shell-words.sh), so a message that
# documents --no-verify is not the flag. commit_judge reads the bypass flags, the first message
# (-m, --message) and every message file (-F, --file).
COMMIT=0; BYPASS=0; MSG=""; MSG_FILES=()
commit_judge() {
  local k=1 a want=""
  [ "${CMD_ARGS[0]:-}" = git ] || return 0
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -c|-C) [ "${CMD_ARGS[k]:-}" != commit.gpgsign=false ] || BYPASS=1; k=$((k + 1)) ;;
      -*) ;;
      commit) COMMIT=1; break ;;
      *) return 0 ;;
    esac
  done
  [ "$a" = commit ] || return 0
  for a in "${CMD_ARGS[@]:k}"; do
    case "$want" in m) [ -n "$MSG" ] || MSG="$a"; want=""; continue ;; F) MSG_FILES+=("$a"); want=""; continue ;; esac
    case "$a" in
      --no-verify|--no-gpg-sign) BYPASS=1 ;;
      -m|--message) want=m ;;
      --message=*) [ -n "$MSG" ] || MSG="${a#*=}" ;;
      -m?*) [ -n "$MSG" ] || MSG="${a#-m}" ;;
      -F|--file) want=F ;;
      --file=*) MSG_FILES+=("${a#*=}") ;;
      -F?*) MSG_FILES+=("${a#-F}") ;;
    esac
  done
}
shell_words "$CMD"
if [ "$SW_OVERFLOW" = 1 ]; then
  # Too long to split: judge the raw text.
  case "$CMD" in *git*commit*) COMMIT=1 ;; esac
  case "$CMD" in *--no-verify*|*--no-gpg-sign*|*commit.gpgsign=false*) BYPASS=1 ;; esac
fi
shell_each_command commit_judge
[ "$COMMIT" = 1 ] || exit 0

# Anti-pattern: --no-verify / --no-gpg-sign / -c commit.gpgsign=false as git arguments.
if [ "$BYPASS" = 1 ]; then
  emit_pre_deny "[BLOCKED] git commit cannot bypass hooks or signing.

Command contains one of: --no-verify, --no-gpg-sign, commit.gpgsign=false (as a git argument, not as message content).

Fix: investigate the underlying issue and address it. Hooks exist to catch real problems (failing tests, lint violations, sentinel-stripping); bypassing them creates silent breakage downstream. See skills/coverage-expansion/SKILL.md and the harness's own rule: \"Never skip hooks (--no-verify) or bypass signing unless the user has explicitly asked for it. If a hook fails, investigate and fix the underlying issue.\""
  exit 0
fi

# --- AI-attribution scan (full-surface, independent of -m extraction) ---
# Scans the ENTIRE command string plus the contents of every resolvable
# message file. This is deliberately independent of the single-subject
# message below: a second `-m` trailer, a heredoc body, a message file, or a
# `--message=` body all land in ATTRIB_SCAN and get checked. The match targets
# attribution TRAILERS and MARKERS specifically (a Co-Authored-By: line naming
# an AI identity, a "Generated with [Claude Code]" marker, or a claude.ai/code
# URL) — NOT any prose mention of the word "claude", so a commit fixing a typo
# that quotes "claude" in its subject still ALLOWs.
ATTRIB_SCAN="$CMD"
for af in ${MSG_FILES[@]+"${MSG_FILES[@]}"}; do
  [ "$af" != "-" ] && [ -f "$af" ] && ATTRIB_SCAN="${ATTRIB_SCAN}
$(cat "$af" 2>/dev/null || true)"
done

# The co-authored-by alternative matches the trailer at a line start OR
# immediately after a quote (covers a second inline `-m 'Co-Authored-By:
# …'` trailer where the whole git command is a single line). The
# generated-with / claude.ai-code alternatives are markers/URLs that are
# never legitimate in a commit message, so they match anywhere.
if echo "$ATTRIB_SCAN" | grep -qiE '(^|['"'"'"])[[:space:]]*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude([[:space:]]+code)?\b|claude\.ai/code'; then
  emit_pre_deny "[BLOCKED] git commit carries AI-attribution metadata.

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

# The message: the first -m / --message, else the first message file when it exists.
if [ -z "$MSG" ] && [ "${#MSG_FILES[@]}" -gt 0 ] && [ "${MSG_FILES[0]}" != "-" ] && [ -f "${MSG_FILES[0]}" ]; then
  MSG=$(cat "${MSG_FILES[0]}" 2>/dev/null || true)
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
  emit_pre_deny "[BLOCKED] Multi-journey commit detected.

Message: \"${SCAN}\"

Fix: split into one commit per journey. The convention from coverage-expansion/references/depth-mode-pipeline.md §\"Commit-message conventions\" is one journey per commit, no exceptions:

  test(j-checkout): cycle-2 — multi-item variant
  test(j-signup): cycle-2 — long-input edge

Why: per-journey commits make the git log filterable by j-<slug>. A multi-journey commit hides which journey a regression came from when bisecting."
  exit 0
fi

# Anti-pattern: feat(e2e): ... — coverage expansion / e2e tests are never `feat`.
if echo "$SCAN" | grep -qiE '^feat\((e2e|tests|test|coverage|journey|onboarding)\)'; then
  emit_pre_deny "[BLOCKED] Test/coverage commits are 'test:' not 'feat:'.

Message: \"${SCAN}\"

Fix: use the convention from coverage-expansion/references/depth-mode-pipeline.md §\"Commit-message conventions\":

  test(<j-slug>): <variant>          for compositional passes
  docs(ledger): <j-slug> — ...       for adversarial pass 4
  test(<j-slug>-regression): ...     for adversarial pass 5
  docs(ledger): dedupe ...           for cleanup

Why: the convention makes commits filterable by type. 'feat(...)' is for product features."
  exit 0
fi

# Anti-pattern: review(...) or any review-tagged commit — Stage B never
# commits per coverage-expansion/references/depth-mode-pipeline.md
# §"Commit-message conventions" and coverage-expansion/SKILL.md
# §"Dual-stage per-pass contract". Reviewer judgements live in the state
# file, not the git log.
if echo "$SCAN" | grep -qiE '^review\('; then
  emit_pre_deny "[BLOCKED] Review-tagged commits are forbidden.

Message: \"${SCAN}\"

Fix: Stage B reviewer judgements go in the state file's per-journey \`review_status\` and \`final_must_fix\` fields, never as commits. The git log records what landed (Stage A's tests, ledger entries, regression locks) — not the review trail.

If you intended a tests-from-Stage-A commit, the right form is:

  test(<j-slug>): <variant>          for compositional passes
  docs(ledger): <j-slug> — ...       for adversarial pass 4
  test(<j-slug>-regression): ...     for adversarial pass 5

See coverage-expansion/references/depth-mode-pipeline.md §\"Commit-message conventions\"."
  exit 0
fi

# Anti-pattern: fix(...) for a new test file (commits adding spec files should
# be `test(...)` per the convention; `fix(...)` is reserved for fixing existing
# code/tests).
# This is a soft check — we can't easily tell if files are new vs modified
# without reading the index. Leave as a doc-level rule for now.

exit 0
