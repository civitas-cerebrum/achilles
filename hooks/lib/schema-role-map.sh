# schema-role-map.sh — single source of truth for the description-prefix
# → return-schema mapping used by both halves of the schema-discipline
# contract:
#
#   PreToolUse:Agent  →  subagent-schema-preread-gate.sh  (DENY mode)
#   PostToolUse:Agent →  subagent-return-schema-guard.sh  (WARN mode)
#
# Drift between the two would create false positives (the pre-gate denies
# a dispatch the post-validator would silent-allow) or false negatives
# (the pre-gate allows what the post-validator considers invalid). This
# file is the canonical mapping; both hooks source it.
#
# Schema files live at schemas/subagent-returns/<role>.schema.json.
# Update both the mapping and the schema directory in lockstep.

# resolve_schema_role <description>
#
# Maps a subagent description string to its return-schema role.
#
# Behaviour:
#   - schema-validated prefix → prints the schema role name (composer,
#     reviewer-inloop, probe, phase-validator) and returns 0.
#   - known prefix with no schema (process-validator-*) → prints an
#     empty string and returns 0. The caller knows the prefix is part
#     of the protocol but has no JSON-Schema enforcement.
#   - unknown / free-form prefix → prints nothing and returns 1. The
#     caller should silent-allow.
#
# Caller pattern:
#
#   if ! SCHEMA_ROLE=$(resolve_schema_role "$DESCRIPTION"); then
#     exit 0   # unknown prefix — out of scope for this hook
#   fi
#   if [ -z "$SCHEMA_ROLE" ]; then
#     # known prefix, no schema — caller-specific handling
#   fi
#   # ... use $SCHEMA_ROLE
resolve_schema_role() {
  case "$1" in
    workflow-reviewer-*) echo "workflow-reviewer"; return 0 ;;
    composer-*)          echo "composer";          return 0 ;;
    reviewer-*)          echo "reviewer-inloop";   return 0 ;;
    probe-*)             echo "probe";             return 0 ;;
    phase-validator-*)   echo "phase-validator";   return 0 ;;
    process-validator-*) echo "";                  return 0 ;;
    *)                   return 1 ;;
  esac
}

# Migration note: workflow-reviewer-* used to live in a post-only superset
# (resolve_schema_role_post, consumed only by subagent-return-schema-guard.sh)
# because the documented reviewer-brief contract did not instruct the
# orchestrator to cite workflow-reviewer.schema.json — pre-gating would have
# rejected exactly the briefs the skill taught. The brief contract now
# REQUIRES the citation (skills/workflow-reviewer/SKILL.md §"Inputs the
# reviewer receives in its brief" input 5; skills/onboarding/SKILL.md
# §"Status ledger + workflow reviewer"), so the mapping was promoted into
# resolve_schema_role and the post-only function was deleted — both the
# PreToolUse preread gate and the PostToolUse return guard now use
# resolve_schema_role directly.
# NOTE: the workflow-reviewer-* case is listed BEFORE reviewer-* for
# clarity; case globs anchor at the string start so there is no actual
# overlap ("workflow-reviewer-…" does not match "reviewer-*").
