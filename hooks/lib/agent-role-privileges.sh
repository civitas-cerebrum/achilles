# agent-role-privileges.sh — single source of truth for the agentic-OS
# role → privilege mapping used by the process-dispatch half and the
# enforcement half of the role-privilege contract:
#
#   PreToolUse:Agent →  agentic-process-registrar.sh   (process creation —
#                       records the dispatch + its role's privilege snapshot)
#   PreToolUse:Bash  →  agent-role-privilege-guard.sh  (syscall filter —
#   PreToolUse:Agent    denies command classes the executing role lacks)
#
# The model is deliberately OS-shaped: dispatching a subagent is process
# creation, the description prefix is the login name, this file is
# /etc/passwd + sudoers, and the guard is the kernel's capability check.
# Drift between the registrar and the guard would let a dispatch record a
# privilege set the guard doesn't enforce (or vice versa) — both halves
# source this file so the mapping cannot fork.
#
# Privilege classes (denied-capability vocabulary)
# ------------------------------------------------
#   payload-ingest — Bash commands that dump subagent payload artifacts
#                    (test source, spill returns, CLI traces, run reports)
#                    into the executing context. Denied to the ORCHESTRATOR:
#                    this is the class that leaks subagent context upward.
#                    The isolation contract's "never hold subagent payload
#                    content" rule, made mechanical.
#   mutate         — write-shaped Bash (git commit, rm/mv/cp/touch/mkdir,
#                    in-place editors, tee, package installs, redirection
#                    into non-scratch paths). Denied to read-only verifier
#                    roles — a reviewer that can rewrite the artifact it
#                    verifies is not a reviewer.
#   browser        — playwright-cli invocations. Denied to text-only roles
#                    (cleanup, phase4-prioritise-author) whose contracts
#                    say "no browser session", AND to the orchestrator
#                    (UI inspection/discovery is subagent work; the
#                    session-agnostic cleanup subcommands stay allowed).
#   app-fetch      — curl/wget dumps of the application surface into the
#                    executing window. Denied to the ORCHESTRATOR: page
#                    and API-response bodies are discovery payload;
#                    bounded probes (-I/--head, -o /dev/null) stay
#                    allowed.
#   dispatch       — spawning further subagents (nested Agent calls). The
#                    methodology is single-level fan-out: only the
#                    orchestrator creates processes. Denied to every known
#                    role.
#   remote-push    — git push. No subagent role publishes; pushing is a
#                    session-owner (orchestrator/human) action.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md
#
# The description-prefix vocabulary below is a superset of
# lib/schema-role-map.sh (which maps only schema-validated roles); the
# two case tables must stay prefix-compatible. Update the reference doc,
# this mapping, and the guard's class detectors in lockstep.

# resolve_privilege_role <description-or-slug>
#
# Maps a subagent description string (or a playwright-cli session slug —
# the convention puts the same role prefix on both ends) to its privilege
# role. Unknown / free-form prefix → prints nothing and returns 1; the
# caller treats the process as UNCONFINED (no role-specific denials —
# fail-open for dispatches outside the methodology's role vocabulary).
resolve_privilege_role() {
  case "$1" in
    perf-reviewer-*)           echo "perf-reviewer";            return 0 ;;
    workflow-reviewer-*)       echo "workflow-reviewer";        return 0 ;;
    composer-*)                echo "composer";                 return 0 ;;
    reviewer-*)                echo "reviewer-inloop";          return 0 ;;
    probe-*)                   echo "probe";                    return 0 ;;
    phase-validator-*)         echo "phase-validator";          return 0 ;;
    process-validator-*)       echo "process-validator";        return 0 ;;
    # prioritise-author before phase4-cycle-* / phase4-* — same ordering
    # rationale as lib/schema-role-map.sh.
    phase4-prioritise-author*) echo "phase4-prioritise-author"; return 0 ;;
    phase4-*)                  echo "section-agent";            return 0 ;;
    phase1-*)                  echo "phase1-discovery";         return 0 ;;
    phase2-*)                  echo "phase2-discovery";         return 0 ;;
    stage2-*)                  echo "stage2-inspector";         return 0 ;;
    cleanup-*)                 echo "cleanup";                  return 0 ;;
    companion-*)               echo "companion";                return 0 ;;
    fd-*)                      echo "failure-diagnosis";        return 0 ;;
    load-run-*)                echo "load-run";                 return 0 ;;
    *)                         return 1 ;;
  esac
}

# role_denied_classes <role>
#
# Prints the space-separated privilege classes DENIED to <role>. Empty
# output = unconfined (no role-specific denials). The vocabulary is the
# five classes documented in the header; the guard owns the per-class
# command detectors.
#
# Read-only verifier roles (reviewers / validators) additionally lose
# `mutate`; text-only roles additionally lose `browser`. Every known
# subagent role loses `dispatch` (single-level fan-out) and `remote-push`.
role_denied_classes() {
  case "$1" in
    # The orchestrator is NOT all-privileged: it loses every class that
    # pulls bulk app/payload data into its window. UI inspection and
    # discovery are subagent work (phase1-discovery, stage2-inspector,
    # composer, probe) — the orchestrator dispatches, it never looks at
    # the app itself. `browser` for the orchestrator exempts the
    # session-agnostic cleanup subcommands (close-all / kill-all / list /
    # install-browser); `app-fetch` covers curl/wget body dumps of the
    # application surface.
    orchestrator)
      echo "payload-ingest browser app-fetch" ;;
    reviewer-inloop|workflow-reviewer|perf-reviewer|phase-validator|process-validator)
      echo "dispatch remote-push mutate" ;;
    cleanup|phase4-prioritise-author)
      echo "dispatch remote-push browser" ;;
    composer|probe|section-agent|phase1-discovery|phase2-discovery|stage2-inspector|companion|failure-diagnosis|load-run)
      echo "dispatch remote-push" ;;
    *)
      echo "" ;;
  esac
}

# role_denies_class <role> <class>
#
# Boolean helper: returns 0 iff <role>'s denied set contains <class>.
role_denies_class() {
  case " $(role_denied_classes "$1") " in
    *" $2 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# OS-user execution mode (role-bound users)
# ---------------------------------------------------------------------------
# When the operator provisions the role users (scripts/agentic-os/
# provision-role-users.sh), each role maps to a real OS user account and
# subagent Bash commands are re-executed under it (agentic-user-exec.sh) —
# privileges become kernel-enforced (file modes/ACLs), not just
# hook-heuristic-enforced. The orchestrator, unconfined, and ambiguous
# contexts keep the session user.

# list_privilege_roles
#
# Prints every known role name (space-separated) — the provisioner
# iterates this so the user roster can never drift from the role map.
list_privilege_roles() {
  echo "composer reviewer-inloop probe workflow-reviewer perf-reviewer phase-validator process-validator section-agent phase4-prioritise-author phase1-discovery phase2-discovery stage2-inspector cleanup companion failure-diagnosis load-run"
}

# role_os_user <role>
#
# Prints the role-bound OS user name (≤32 chars, `achl-` namespace).
# Returns 1 for contexts that stay on the session user (orchestrator,
# unconfined, ambiguous).
role_os_user() {
  case "$1" in
    composer)                 echo "achl-composer" ;;
    reviewer-inloop)          echo "achl-reviewer" ;;
    probe)                    echo "achl-probe" ;;
    workflow-reviewer)        echo "achl-wfreviewer" ;;
    perf-reviewer)            echo "achl-perfreview" ;;
    phase-validator)          echo "achl-phaseval" ;;
    process-validator)        echo "achl-procval" ;;
    section-agent)            echo "achl-section" ;;
    phase4-prioritise-author) echo "achl-prioritise" ;;
    phase1-discovery)         echo "achl-phase1" ;;
    phase2-discovery)         echo "achl-phase2" ;;
    stage2-inspector)         echo "achl-stage2" ;;
    cleanup)                  echo "achl-cleanup" ;;
    companion)                echo "achl-companion" ;;
    failure-diagnosis)        echo "achl-fd" ;;
    load-run)                 echo "achl-loadrun" ;;
    *)                        return 1 ;;
  esac
}

# role_os_tier <role>
#
# Filesystem tier for the role's OS user: "read" (verifier family — no
# write grants beyond the world/tmp) or "write" (working roles — rwX on
# the working surfaces). Derived from the mutate denial so the OS layer
# can never be more permissive than the hook layer says.
role_os_tier() {
  if role_denies_class "$1" mutate; then echo "read"; else echo "write"; fi
}
