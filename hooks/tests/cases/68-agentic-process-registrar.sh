#!/bin/bash
# Tests for agentic-process-registrar.sh — PreToolUse:Agent process-table
# registrar. Always silent-allow; the side effect is the process table
# written under <project>/.achilles/.agent-process-table.json with the
# dispatched role + its privilege snapshot.
H="$HOOK_DIR/agentic-process-registrar.sh"

# Isolated test repo so the achilles repo's own .achilles is never polluted.
TMPOS=$(mktemp -d)
trap 'rm -rf "$TMPOS"' EXIT
( cd "$TMPOS" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
TBL="$TMPOS/.achilles/.agent-process-table.json"

section "process-registrar: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls' cwd="$TMPOS")" "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path='/tmp/x' content='y' cwd="$TMPOS")" "Write → silent allow"

section "process-registrar: known role prefix registers with privilege snapshot"
rm -rf "$TMPOS/.achilles"
P=$(payload tool_name=Agent description='composer-j-checkout-1-c1: compose the checkout journey' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_comp_001"}')
assert_allow "$H" "$P" "composer dispatch → silent allow"
assert_eq "$("$JQ" -r '.toolu_comp_001.role // "MISSING"' "$TBL" 2>/dev/null)" "composer" "table entry role = composer"
assert_eq "$("$JQ" -cr '.toolu_comp_001.denied // []' "$TBL" 2>/dev/null)" '["dispatch","remote-push"]' "composer denied = dispatch + remote-push"

section "process-registrar: reviewer family registers with mutate denial"
P=$(payload tool_name=Agent description='workflow-reviewer-phase1: verify phase 1 exit criteria' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_wr_001"}')
assert_allow "$H" "$P" "workflow-reviewer dispatch → silent allow"
assert_eq "$("$JQ" -r '.toolu_wr_001.role // "MISSING"' "$TBL" 2>/dev/null)" "workflow-reviewer" "table entry role = workflow-reviewer"
assert_eq "$("$JQ" -r '.toolu_wr_001.denied | index("mutate") != null' "$TBL" 2>/dev/null)" "true" "workflow-reviewer denied includes mutate"

section "process-registrar: text-only role registers with browser denial"
P=$(payload tool_name=Agent description='cleanup-pass-5: consolidate the findings ledger' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_cl_001"}')
assert_allow "$H" "$P" "cleanup dispatch → silent allow"
assert_eq "$("$JQ" -r '.toolu_cl_001.denied | index("browser") != null' "$TBL" 2>/dev/null)" "true" "cleanup denied includes browser"

section "process-registrar: free-form prefix registers as unconfined (load-bearing for intersection fallback)"
P=$(payload tool_name=Agent description='Explore the docs directory and summarise' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_free_001"}')
assert_allow "$H" "$P" "free-form dispatch → silent allow"
assert_eq "$("$JQ" -r '.toolu_free_001.role // "MISSING"' "$TBL" 2>/dev/null)" "unconfined" "table entry role = unconfined"
assert_eq "$("$JQ" -cr '.toolu_free_001.denied // ["MISSING"]' "$TBL" 2>/dev/null)" '[]' "unconfined denied = empty"

section "process-registrar: missing tool_use_id silent-allows without writing"
rm -rf "$TMPOS/.achilles"
assert_allow "$H" "$(payload tool_name=Agent description='composer-j-x-1-c1: compose' cwd="$TMPOS")" "no tool_use_id → silent allow"
TESTS_RUN=$((TESTS_RUN+1))
[ ! -f "$TBL" ] && { TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} no table written when tool_use_id absent"; } || { TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} table written despite missing tool_use_id"; }

section "process-registrar: stale entries expire on the next registration (30-min TTL)"
rm -rf "$TMPOS/.achilles"
mkdir -p "$TMPOS/.achilles"
OLD_TS=$(( $(date +%s) - 4000 ))
echo "{\"toolu_stale\": {\"role\": \"composer\", \"denied\": [\"dispatch\",\"remote-push\"], \"description\": \"composer-j-old-1-c1\", \"ts\": $OLD_TS}}" > "$TBL"
P=$(payload tool_name=Agent description='probe-j-checkout-4: adversarial probe' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_probe_001"}')
assert_allow "$H" "$P" "probe dispatch over stale table → silent allow"
assert_eq "$("$JQ" -r 'has("toolu_stale")' "$TBL" 2>/dev/null)" "false" "stale entry expired"
assert_eq "$("$JQ" -r '.toolu_probe_001.role // "MISSING"' "$TBL" 2>/dev/null)" "probe" "fresh probe entry present"

section "process-registrar: malformed table is replaced, not fatal"
echo 'not-json' > "$TBL"
P=$(payload tool_name=Agent description='reviewer-j-checkout-1-c1: review the composition' cwd="$TMPOS")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_rev_001"}')
assert_allow "$H" "$P" "dispatch over malformed table → silent allow"
assert_eq "$("$JQ" -r '.toolu_rev_001.role // "MISSING"' "$TBL" 2>/dev/null)" "reviewer-inloop" "table rebuilt with reviewer-inloop entry"
