# dispatch-prefix.sh — every skill name and dispatch-description / CLI-slug prefix
# grammar the hooks match on. Sourced by lib/achilles-activation.sh, so every gate
# that checks activation has these names. lib/schema-role-map.sh keeps its own
# literal case labels (scripts/lint-doc-drift.mjs check 4 parses them).
# Activation is the root of trust: an alternative dropped here turns every gate off
# for that role. hooks/tests/cases/89-dispatch-prefix-activation.sh pins the activation prefixes and the
# skill list; the other grammars are exercised by the gates' own cases.

# Skill names bundled by this package (skills/<name>/). Any Skill invocation of one
# of these — bare or plugin/path-prefixed — activates the protocol for the session;
# a name missing here activates nothing (scripts/lint-doc-drift.mjs check 9 parses
# this line). `element-interactions` is the orchestrator's pre-rename skill name
# (not the npm package), kept so installs still carrying the old directory activate.
ACHILLES_SKILL_ALT='achilles-protocol|agents-vs-agents|bug-discovery|bug-report|companion-mode|ticket-driven-testing|self-repair|contract-testing|contributing-to-achilles-protocol|coverage-expansion|database-testing|element-interactions|failure-diagnosis|journey-mapping|onboarding|perf-onboarding|performance-testing|plumber|requirement-intake|secrets-sweep|selector-development|test-catalogue|test-composer|test-data-conventions|test-repair|work-summary-deck|workflow-reviewer'

# Pre-kernel description and CLI-slug spelling of the composer role; activates
# gates, never grants (the kernel resolves no role from it). Kept because sessions
# run with KERNEL_MANDATE=0 still dispatch it.
ACHILLES_LEGACY_COMPOSER_PREFIX='composer-'

# Distinctly-achilles subagent description prefixes (backstop for briefs issued
# without a prior Skill call, e.g. external CLI drivers). Generic-sounding prefixes
# (cleanup-, companion-, phase1-, stage2-, reviewer-, fd-, scaffolder-) are left out
# on purpose: a dev's "cleanup-temp:" agent must not switch the guards on, and the
# Phase 1 scaffolder dispatch always follows the `onboarding` Skill call.
# `composer-` here is ACHILLES_LEGACY_COMPOSER_PREFIX, spelled out so case 71 can
# parse the alternation. standard-mode-first-pass-guard.sh Rule 2 additionally keys on
# `^[[:space:]]*phase4-prioritise-author:` (the colon-terminated form of the alternative above).
ACHILLES_DISPATCH_PREFIX_RE='^[[:space:]]*(workflow-reviewer-|perf-reviewer-|phase-validator-|phase4-cycle-|phase4-prioritise-author|secrets-sweep-|test-composer-|composer-|probe-|process-validator-|contribution-handover-)'

# Grouped dispatch: role-first `<role>-group-<id>:` / `<role>-p3batch-<id>:`, or the
# legacy leading `[group]` / `[P3-batch]` markers.
DISPATCH_GROUPED_RE='^[[:space:]]*(\[(group|P3-batch)\]|(test-composer|probe)-(group|p3batch)-[a-z0-9-]+:)'

# playwright-cli `-s=<slug>` role prefixes — the description prefix of the dispatching
# subagent (skills/achilles-protocol/references/playwright-cli-protocol.md §3.1). The
# non-empty suffix rejects a bare `phase1-`; bare `j-`/`sj-` are role-ambiguous and
# rejected. `composer` is the short form that fits the 28-char socket-path budget;
# `test-composer` matches a slug spelled like its kernel-mandate description.
DISPATCH_SLUG_PREFIX_RE='^(phase1|phase2|phase4|stage2|test-composer|composer|reviewer|probe|cleanup|companion|fd)-[a-z0-9][a-z0-9-]*'

# sed -E captures of the phase a reviewer dispatch targets (lib/pipeline-gate.sh
# reviewer-cycle cap).
DISPATCH_CAP_PREFIX_RE_ONBOARDING='s/^(workflow-reviewer-phase|phase-validator-)([0-9]+).*/\2/p'
DISPATCH_CAP_PREFIX_RE_PERF='s/^(perf-reviewer-phase)([0-9]+).*/\2/p'

# Phase-5 pass number of a composer/probe dispatch. Unanchored, so the kernel spelling
# `test-composer-j-<slug>-<pass>` matches through its `composer-j-` tail.
DISPATCH_PHASE5_PASS_RE='(composer|probe)-j-[a-z0-9-]+-[1-5]'

# Roles that put a session into failure diagnosis.
DISPATCH_FD_ROLE_ALT='fd|repair-worker'

# is_reviewer_description <description> → 0 when the description carries an
# approver-role prefix (workflow-reviewer-*, phase-validator-<N>, perf-reviewer-*).
is_reviewer_description() {
  echo "$1" | grep -qE '^[[:space:]]*(workflow-reviewer-[a-z0-9-]+|phase-validator-[0-9]+|perf-reviewer-[a-z0-9-]+)[:_-]'
}

# is_phase4_mapping_description <description> → 0 for a journey-mapping cycle section
# agent or the Phase-4 prioritisation author.
is_phase4_mapping_description() {
  case "$1" in
    phase4-cycle-*|phase4-prioritise-author*) return 0 ;;
  esac
  return 1
}

# is_multi_section_consumer <description> → 0 for roles whose briefs legitimately
# name several journey-map sections (authors, validators, reviewers, composers).
is_multi_section_consumer() {
  case "$1" in
    phase4-prioritise-author:*|phase-validator-*|process-validator-*|cleanup-*|workflow-reviewer-*|secrets-sweep-*|test-composer-*|"$ACHILLES_LEGACY_COMPOSER_PREFIX"*|reviewer-*|probe-*|phase[1-8]-*) return 0 ;;
  esac
  return 1
}

# dispatch_phase_number <onboarding|perf> <description> → prints the pipeline phase a
# dispatch targets, or nothing.
dispatch_phase_number() {
  case "$1" in
    onboarding)
      case "$2" in
        phase1-*|phase1_*) echo 1 ;;
        phase2-*|phase2_*) echo 2 ;;
        phase3-*|phase3_*) echo 3 ;;
        phase4-*|phase4_*) echo 4 ;;
        phase5-*|phase5_*) echo 5 ;;
        phase6-*|phase6_*) echo 6 ;;
        phase7-*|phase7_*) echo 7 ;;
        phase8-*|phase8_*) echo 8 ;;
        secrets-sweep-*|secrets_sweep-*) echo 7 ;;
        work-summary-deck-*|qa-summary-*) echo 8 ;;
      esac
      ;;
    perf)
      case "$2" in
        scaffold-perf-*|scaffold_perf-*) echo 1 ;;
        readiness-*|readiness_*) echo 2 ;;
        scenario-model-*|scenario_model-*) echo 3 ;;
        baseline-*|baseline_*) echo 4 ;;
        load-run-*|load_run-*) echo 5 ;;
        threshold-gate-*|threshold_gate-*) echo 6 ;;
        perf-report-*|perf_report-*) echo 7 ;;
      esac
      ;;
  esac
}
