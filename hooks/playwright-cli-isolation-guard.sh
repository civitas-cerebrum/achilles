#!/bin/bash
# playwright-cli-isolation-guard.sh — playwright-cli session-isolation enforcer
#
# Hook    : PreToolUse:Bash  (filters to commands that mention `playwright-cli`)
# Mode    : DENY (missing -s=, collision-prone slug, missing role prefix, length cap)
# State   : none
# Env     : none
#
# Rule
# ----
# Every `playwright-cli` invocation must run in a role-prefixed isolated
# session. The `-s=<slug>` flag is required (except for session-agnostic
# subcommands like close-all / kill-all / list / install-browser /
# --version / --help). The slug must:
#   1. Begin with a recognized role prefix (DISPATCH_SLUG_PREFIX_RE in
#      lib/dispatch-prefix.sh). phase4-c<N>-s-<section-id> covers
#      journey-mapping iterative-cycle section agents (cycle protocol per
#      skills/journey-mapping/SKILL.md §"Iterative discovery cycles").
#   2. Not match a collision-prone reserved word (default, test, session, …).
#   3. Be 6–28 characters (the macOS UNIX-socket-path cap leaves ~28 chars
#      of slug headroom under $TMPDIR/pw-XXXXXXXX/cli/<16-hash>-<slug>.sock).
#
# Why
# ---
# Slug = browser process. Two parallel subagents that share a slug fight
# over one Chrome instance — the second's `open` reuses the first's
# user-data-dir and isolation breaks silently. The role prefix locks the
# subagent description ↔ CLI slug into a 1:1 mapping: `.playwright-cli/<slug>*`
# trace files attribute to exactly one subagent. The length cap exists
# because the playwright-cli daemon binds a UNIX socket whose path overflows
# silently (EINVAL) past 104 bytes on darwin.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/playwright-cli-protocol.md §3
#   (Session model, naming convention, length budget, quarantine)
#
# Convention (subagent description prefix ↔ CLI slug — same role on both ends)
# ------------------------------------------------------------------------------
#   test-composer-j-<slug>:  →  composer-j-<slug>-<pass>-c<N>   (slug drops `test-`
#   test-composer-sj-<slug>: →  composer-sj-<slug>-<pass>-c<N>   to fit the cap)
#   composer-j-<slug>:    →  composer-j-<slug>-<pass>-c<N>
#   composer-sj-<slug>:   →  composer-sj-<slug>-<pass>-c<N>
#   reviewer-j-<slug>:    →  reviewer-j-<slug>-<pass>-c<N>
#   reviewer-sj-<slug>:   →  reviewer-sj-<slug>-<pass>-c<N>
#   probe-j-<slug>:       →  probe-j-<slug>-<pass>
#   phase1-<entry>:       →  phase1-<entry>
#   phase2-<scope>:       →  phase2-<scope>
#   stage2-<scenario>:    →  stage2-<scenario>
#   cleanup-<scope>:      →  cleanup-<scope>
#   (companion- and fd- prefixes accepted for companion-mode / failure-diagnosis)
#
# Bare `j-<slug>-...` / `sj-<slug>-...` slugs deny: the slug must name the
# dispatching subagent's role (composer-/reviewer-/probe-).
#
# Failure → action
# ----------------
# - Missing `-s=` flag                                          → DENY
# - Slug in collision-prone blocklist                           → DENY
# - Slug missing role prefix                                    → DENY
# - Slug shorter than 6 chars                                   → DENY
# - Slug longer than 28 chars                                   → DENY (length-cap)
# - playwright-cli named where the guard cannot read the invocation → DENY
# - Session-agnostic subcommand (close-all / kill-all / list / install-browser / etc.) → silent allow
# - Anything else                                               → silent allow

set -euo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/achilles-protocol/references/playwright-cli-protocol.md §3\n  skills/achilles-protocol/SKILL.md §11 (browser automation goes through @playwright/cli)"


# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib hook-emit.sh shell-words.sh
hook_jq_init fatal

hook_read_input

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
hook_lib achilles-activation.sh
achilles_require_active "$INPUT"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""')

# Judge every command the shell would run (lib/shell-words.sh). A command whose words, assignments or
# heredoc bodies name playwright-cli (@playwright/cli, in any letter case: APFS is case-insensitive)
# is DENY unless it is playwright-cli itself, plain or behind the wrappers the splitter peels (npx,
# bunx, pnpm|yarn exec, env, time, …), whose slug is judged below, or a reader that does not execute
# its arguments (is_exempt_command). Obfuscated or exotic shell forms are out of scope (known-limits.md KL-15).
CMD_PREVIEW="$CMD"
[ ${#CMD} -le 160 ] || CMD_PREVIEW="${CMD:0:160}..."

pw_mention() {
  local rc=1
  shopt -s nocasematch
  case "$1" in *playwright-cli*|*@playwright/cli*) rc=0 ;; esac
  shopt -u nocasematch
  return "$rc"
}

pw_command_word() {
  local rc=1
  shopt -s nocasematch
  case "$1" in playwright-cli|@playwright/cli) rc=0 ;; esac
  shopt -u nocasematch
  return "$rc"
}

# The command word is a reader that does not execute its arguments.
is_exempt_command() {
  local a
  [ "$CMD_ENV" = 0 ] || return 1
  case "${CMD_ARGS[0]:-}" in
    echo|cat|head|tail|tee|grep|egrep|fgrep|ls|wc|which|type|jq|pgrep) return 0 ;;
    printf) for a in "${CMD_ARGS[@]:1}"; do case "$a" in -v|-v?*) return 1 ;; --) break ;; esac; done; return 0 ;;
    command) case "${CMD_ARGS[1]:-}" in -v|-V) return 0 ;; esac ;;
    npm) case "${CMD_ARGS[1]:-}" in ls|list|view|info) return 0 ;; esac ;;
    git) case "${CMD_ARGS[1]:-}" in commit|log|show|diff|status|add|grep|tag|branch) return 0 ;; esac ;;
  esac
  return 1
}

deny_unjudgeable() {
  emit_pre_deny "[BLOCKED] Cannot judge this command: $1.

Command: $CMD_PREVIEW

Fix: run playwright-cli as a literal command word, with its slug and no wrapper the guard does not know.

  npx playwright-cli -s=<slug> <subcommand> ...

Why: a wrapper or program the guard does not know (sudo, setsid, sh -c, eval …), an unrecognised wrapper option, or the name passed as text may run playwright-cli without -s=<slug>, and the guard cannot see inside it. Wrappers it peels: hooks/lib/shell-words.sh. Readers it lets through: is_exempt_command in this hook."
  exit 0
}

judge_invocation() {
  local k=1 a SLUG="" mentioned=0
  for a in ${CMD_ARGS[@]+"${CMD_ARGS[@]}"} ${CMD_HEREDOCS[@]+"${CMD_HEREDOCS[@]}"} ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do
    if pw_mention "$a"; then mentioned=1; break; fi
  done
  [ "$mentioned" = 1 ] || return 0
  if ! pw_command_word "${CMD_ARGS[0]:-}" || [ "$CMD_WRAP_BAD" = 1 ]; then
    is_exempt_command && return 0
    deny_unjudgeable "playwright-cli is named where the guard cannot read the invocation"
  fi
  # Session-agnostic subcommands run without -s= by design; no argument prints the help.
  case "${CMD_ARGS[1]:-}" in
    ''|install-browser|close-all|kill-all|list|list-sessions|sessions|--help|-h|--version|-v) return 0 ;;
  esac
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -s=*) SLUG="${a#-s=}"; break ;;
      -s) SLUG="${CMD_ARGS[k]:-}"; break ;;
    esac
  done

  # Case 1: -s= flag is missing entirely.
  if [ -z "$SLUG" ]; then
    emit_pre_deny "[BLOCKED] Missing -s=<slug> flag.

Command: $CMD_PREVIEW

Fix: add an isolated session slug matching this subagent's role.

  npx playwright-cli -s=<slug> <subcommand> ...

Slug convention (must match the Agent description prefix that dispatched this subagent):

  composer-j-<slug>-<pass>-c<N>          composer (Stage A)
  reviewer-j-<slug>-<pass>-c<N>          reviewer (Stage B)
  probe-j-<slug>-<pass>                  adversarial probe
  composer-sj-<slug>-<pass>-c<N>         sub-journey composer
  phase1-<entry>                         Phase-1 discovery
  stage2-<scenario>                      element inspection
  cleanup-<scope>                        ledger / cleanup

Why: without -s=, playwright-cli uses the shared default session — two parallel subagents fight over one browser process and isolation breaks. See achilles-protocol Rule 11 + playwright-cli-protocol.md §3.1."
    exit 0
  fi

  # Case 2: slug is in collision-prone blocklist.
  case "$SLUG" in
    default|test|session|temp|tmp|x|y|main|stage1|stage3|stage4|pass1|pass2|pass3|pass4|pass5)
      emit_pre_deny "[BLOCKED] Slug '-s=$SLUG' is collision-prone.

Command: $CMD_PREVIEW

Fix: use a slug that names the specific subagent context, matching the dispatching Agent's description prefix:

  composer-j-<slug>-<pass>-c<N>
  reviewer-j-<slug>-<pass>-c<N>
  probe-j-<slug>-<pass>
  phase1-<entry>
  stage2-<scenario>
  cleanup-<scope>

Why: when two subagents both use '-s=$SLUG', the second's open reuses the first's browser and isolation breaks silently. See playwright-cli-protocol.md §3.1."
      exit 0
      ;;
  esac

  # Case 3: slug doesn't follow the role-prefix convention.
  if ! echo "$SLUG" | grep -qE "$DISPATCH_SLUG_PREFIX_RE"; then
    emit_pre_deny "[BLOCKED] Slug '-s=$SLUG' missing role prefix.

Command: $CMD_PREVIEW

Fix: prefix the slug with this subagent's role so .playwright-cli/<slug>* files trace 1:1 to it.

  -s=composer-j-<journey-slug>-<pass>-c<N>   composer (Stage A)
  -s=reviewer-j-<journey-slug>-<pass>-c<N>   reviewer (Stage B)
  -s=probe-j-<journey-slug>-<pass>           adversarial probe
  -s=phase1-<entry>                          Phase-1 discovery
  -s=stage2-<scenario>                       element inspection

Allowed prefixes: composer- | test-composer- | reviewer- | probe- | phase1- | phase2- | phase4- | stage2- | cleanup- | companion- | fd-

Bare \`j-\` and \`sj-\` slug prefixes are rejected — they're role-ambiguous. Use \`composer-j-<slug>\`, \`reviewer-j-<slug>\`, or \`probe-j-<slug>\` based on the dispatching subagent's role.

Why: a slug without a role prefix is unreviewable — you can't tell from .playwright-cli/<slug>* which subagent or pass produced the artifacts. The convention also locks subagent description ↔ CLI slug into a mechanical mapping (same prefix on both ends). See playwright-cli-protocol.md §3.1."
    exit 0
  fi

  # Case 4: slug is too short even with prefix (defense-in-depth).
  if [ ${#SLUG} -lt 6 ]; then
    emit_pre_deny "[BLOCKED] Slug '-s=$SLUG' is too short (≥6 chars required).

Command: $CMD_PREVIEW

Fix: add the scope after the role prefix.

  -s=composer-j-checkout-1-c1    not    -s=composer-x

Why: ≥6 chars + role prefix is required to disambiguate parallel subagents. See playwright-cli-protocol.md §3.1."
    exit 0
  fi

  # Case 5: slug is too long. The playwright-cli daemon binds a UNIX socket
  # under \$TMPDIR; on macOS the socket path is capped at 104 chars. Slugs
  # longer than ~28 chars push the path over the limit and the daemon
  # silently fails with EINVAL on bind.
  if [ ${#SLUG} -gt 28 ]; then
    emit_pre_deny "[BLOCKED] Slug '-s=$SLUG' is too long (${#SLUG} chars; ≤28 allowed).

Command: $CMD_PREVIEW

Fix: shorten the journey slug while keeping the role prefix and the journey identifier. Common abbreviations:

  composer-j-<long-journey-slug>-<pass>-c<N>  →  composer-j-<short-slug>-<pass>-c<N>
  reviewer-j-<long-journey-slug>-<pass>-c<N>  →  reviewer-j-<short-slug>-<pass>-c<N>

Examples that fit:
  composer-j-checkout-1-c1     (24 chars — role:composer, journey:j-checkout, pass:1, cycle:1)
  reviewer-j-checkout-1-c2     (24 chars)
  probe-j-checkout-4           (18 chars)
  phase1-public                (13 chars)

Why: the playwright-cli daemon binds a UNIX socket under \$TMPDIR. Long slugs push the socket path over the 104-char macOS limit and the daemon silently fails to bind (EINVAL). See playwright-cli-protocol.md §3.1."
    exit 0
  fi
}

shell_words "$CMD"
shell_each_command judge_invocation
exit 0
