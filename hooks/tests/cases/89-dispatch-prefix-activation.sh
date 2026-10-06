#!/bin/bash
# Activation is the root of trust: a dispatch prefix or skill name dropped from the
# shared grammar silently turns every gate off for that role. Each one is listed here
# by hand, so a dropped alternative fails a named assertion and an added one fails the
# exact-set pin until it is listed (with its schema role) below.
WATCHER="$HOOK_DIR/achilles-protocol-activation-watcher.sh"
DP_TMP=$(mktemp -d)
export ACHILLES_SESSION_STATE_DIR="$DP_TMP/sessions"
unset ACHILLES_PROTOCOL

marked() { [ -f "$ACHILLES_SESSION_STATE_DIR/$1.active" ] && echo marked || echo unmarked; }
# The lib as a gate loads it: sourced fresh, asked about one payload.
lib_active() { ( . "$HOOK_DIR/lib/achilles-activation.sh"; achilles_session_active "$1" ) && echo active || echo inactive; }
role_of() {
  local r
  if r=$( . "$HOOK_DIR/lib/schema-role-map.sh"; resolve_schema_role "$1"); then printf '%s' "${r:-<envelope>}"; else printf '<unmapped>'; fi
}
lib_value() { ( . "$HOOK_DIR/lib/achilles-activation.sh"; printf '%s' "${!1}" ); }
dispatch() { payload session_id="$1" hook_event_name=PreToolUse tool_name=Agent description="$2"; }

# <prefix> <schema role of "<prefix>x: y">
DISPATCH_PREFIXES='workflow-reviewer- workflow-reviewer
perf-reviewer- perf-reviewer
phase-validator- phase-validator
phase4-cycle- section-agent
phase4-prioritise-author phase4-prioritise-author
secrets-sweep- composer
test-composer- composer
composer- composer
probe- probe
process-validator- <envelope>
contribution-handover- <unmapped>'

SKILLS='achilles-protocol agents-vs-agents bug-discovery bug-report companion-mode ticket-driven-testing self-repair contract-testing contributing-to-achilles-protocol coverage-expansion database-testing element-interactions failure-diagnosis journey-mapping onboarding perf-onboarding performance-testing secrets-sweep selector-development test-catalogue test-composer test-data-conventions test-repair work-summary-deck workflow-reviewer'

section "dispatch prefixes: the alternation is exactly the listed set"
LISTED=$(printf '%s\n' "$DISPATCH_PREFIXES" | cut -d' ' -f1 | sort | tr '\n' ' ')
PARSED=$(lib_value ACHILLES_DISPATCH_PREFIX_RE | sed -E 's/^\^\[\[:space:\]\]\*\((.*)\)$/\1/' | tr '|' '\n' | sort | tr '\n' ' ')
assert_eq "$PARSED" "$LISTED" "ACHILLES_DISPATCH_PREFIX_RE alternatives == the prefixes pinned below"
assert_eq "$(lib_value ACHILLES_SKILL_ALT | tr '|' '\n' | sort | tr '\n' ' ')" "$(printf '%s\n' $SKILLS | sort | tr '\n' ' ')" \
  "ACHILLES_SKILL_ALT == the skills pinned below"

section "dispatch prefixes: each activates and resolves its schema role"
n=0
while read -r PFX ROLE; do
  n=$((n + 1)); D="${PFX}x: y"
  assert_allow "$WATCHER" "$(dispatch "dp-w$n" "$D")" "watcher: '$D' → silent"
  assert_eq "$(marked "dp-w$n")" "marked" "watcher marks the session on '$D'"
  assert_eq "$(lib_active "$(dispatch "dp-l$n" "$D")")" "active" "achilles_session_active on a fresh session: '$D'"
  assert_eq "$(role_of "$D")" "$ROLE" "resolve_schema_role '$D' → $ROLE"
done <<< "$DISPATCH_PREFIXES"
assert_eq "$(lib_active "$(dispatch dp-ws '  probe-x: y')")" "active" "leading whitespace before the prefix still activates"
for D in 'test-composer-group-g1: j-a, j-b' 'test-composer-p3batch-b1: j-a, j-b' 'probe-group-g1: j-a, j-b' 'probe-p3batch-b1: j-a, j-b'; do
  assert_eq "$(lib_active "$(dispatch "dp-g$n" "$D")")" "active" "grouped '$D' activates"
  assert_eq "$(role_of "$D")" "<envelope>" "grouped '$D' → envelope check only"
  n=$((n + 1))
done

section "dispatch prefixes: generic-sounding roles do not activate on their own"
for D in 'cleanup-x: y' 'scaffolder-phase1: y' 'stage2-x: y'; do
  n=$((n + 1))
  assert_allow "$WATCHER" "$(dispatch "dp-n$n" "$D")" "watcher: '$D' → silent"
  assert_eq "$(marked "dp-n$n")" "unmarked" "watcher leaves the session unmarked on '$D'"
  assert_eq "$(lib_active "$(dispatch "dp-m$n" "$D")")" "inactive" "achilles_session_active stays off for '$D'"
done

section "skills: each activates through a Skill call"
for S in $SKILLS; do
  assert_allow "$WATCHER" "$(payload session_id="dp-s-$S" hook_event_name=PreToolUse tool_name=Skill skill="$S")" "watcher: Skill($S) → silent"
  assert_eq "$(marked "dp-s-$S")" "marked" "watcher marks the session on Skill($S)"
  assert_eq "$(lib_active "$(payload session_id="dp-k-$S" hook_event_name=PreToolUse tool_name=Skill skill="$S")")" "active" \
    "achilles_session_active on a fresh session: Skill($S)"
done
assert_eq "$(lib_active "$(payload session_id=dp-md hook_event_name=PreToolUse tool_name=Skill skill=mandate-designer)")" "inactive" \
  "Skill(mandate-designer) does not activate (generic kernel tool)"

rm -rf "$DP_TMP"
