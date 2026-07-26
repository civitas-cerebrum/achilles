#!/bin/bash
# Tests for agentic-user-exec.sh — role-bound OS-user execution rewriter.
# Fires only when: user-mode not off, provision marker present, subagent
# context (agent_id), EXACT role resolution, role maps to a provisioned
# OS user, command not already wrapped. Everything else: silent allow.
H="$HOOK_DIR/agentic-user-exec.sh"

TMPUX=$(mktemp -d)
trap 'rm -rf "$TMPUX"' EXIT
( cd "$TMPUX" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
mkdir -p "$TMPUX/.achilles"
TBL="$TMPUX/.achilles/.agent-process-table.json"
MARKER="$TMPUX/enabled-marker"
printf 'achl-composer\nachl-reviewer\nachl-cleanup\n' > "$MARKER"

NOW=$(date +%s)
seed_one() {
  echo "{\"toolu_$1\": {\"role\": \"$1\", \"denied\": [], \"description\": \"$1\", \"ts\": $NOW}}" > "$TBL"
}

# run_exec <payload> — run the hook with the test marker; output in HOOK_OUT.
run_exec() {
  HOOK_EXIT=0
  HOOK_OUT=$(printf '%s' "$1" | AGENTIC_OS_MARKER="$MARKER" bash "$H" 2>/dev/null) || HOOK_EXIT=$?
}

# assert_rewrite <payload> <case-name> <expected-user> <expected-cmd-substring>
assert_rewrite() {
  local stdin="$1" name="$2" user="$3" substr="$4"
  TESTS_RUN=$((TESTS_RUN + 1))
  run_exec "$stdin"
  local decision updated
  decision=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  updated=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
  if [ "$decision" = "allow" ] \
    && echo "$updated" | grep -qF -- "-u ${user} " \
    && echo "$updated" | grep -qE '^sudo -n ' \
    && echo "$updated" | grep -qF -- "$substr"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} ${name}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("${name}: expected allow+updatedInput as ${user}, got decision='${decision}' cmd='${updated:0:160}'")
    echo "${CLR_FAIL}  ✗${CLR_RST} ${name} ${CLR_DIM}(expected rewrite to ${user})${CLR_RST}"
  fi
}

# assert_noop <payload> <case-name> — silent allow with the marker present.
assert_noop() {
  local stdin="$1" name="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  run_exec "$stdin"
  if [ -z "$HOOK_OUT" ] && [ "$HOOK_EXIT" -eq 0 ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} ${name}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("${name}: expected silent allow, got exit=${HOOK_EXIT} output=${HOOK_OUT:0:160}")
    echo "${CLR_FAIL}  ✗${CLR_RST} ${name} ${CLR_DIM}(expected silent allow)${CLR_RST}"
  fi
}

section "user-exec: inactive without the provision marker"
seed_one composer
NOMARKER_OUT=$(printf '%s' "$(payload tool_name=Bash command='ls' cwd="$TMPUX" agent_id=sub_c parent_tool_use_id=toolu_composer)" | AGENTIC_OS_MARKER="$TMPUX/absent-marker" bash "$H" 2>/dev/null)
assert_eq "$NOMARKER_OUT" "" "marker absent → silent allow (exact role notwithstanding)"

section "user-exec: activation gating with the marker present"
assert_noop "$(payload tool_name=Bash command='ls tests/' cwd="$TMPUX")" \
  "orchestrator (no agent_id) → no rewrite"
assert_noop "$(payload tool_name=Write file_path=/tmp/x content=y cwd="$TMPUX" agent_id=sub_c)" \
  "non-Bash tool → no rewrite"

section "user-exec: exact role resolution rewrites to the role user"
seed_one composer
assert_rewrite "$(payload tool_name=Bash command='npx playwright test tests/e2e/journeys/checkout.spec.ts' cwd="$TMPUX" agent_id=sub_c parent_tool_use_id=toolu_composer)" \
  "composer via parent_tool_use_id → sudo as achl-composer" "achl-composer" "npx playwright test"
seed_one reviewer-inloop
assert_rewrite "$(payload tool_name=Bash command='git diff tests/e2e/journeys/checkout.spec.ts' cwd="$TMPUX" agent_id=sub_r)" \
  "reviewer via single-live-role → sudo as achl-reviewer" "achl-reviewer" "git diff"
rm -f "$TBL"
assert_rewrite "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-checkout-1-c1 open https://x' cwd="$TMPUX" agent_id=sub_c)" \
  "composer via -s=<slug> claim, no table → sudo as achl-composer" "achl-composer" "playwright-cli"

section "user-exec: single-quote-safe wrapping"
seed_one composer
P=$(payload tool_name=Bash command="echo 'hello world'" cwd="$TMPUX" agent_id=sub_c parent_tool_use_id=toolu_composer)
run_exec "$P"
INNER=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.updatedInput.command' 2>/dev/null)
# Round-trip: strip the wrapper, execute the inner bash -c payload, and
# confirm the original command semantics survived the quoting.
ROUNDTRIP=$(eval "${INNER#sudo -n --preserve-env=PATH,TMPDIR,PLAYWRIGHT_BROWSERS_PATH,PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD --set-home -u achl-composer -- }" 2>/dev/null)
assert_eq "$ROUNDTRIP" "hello world" "quoted command round-trips through the wrapper"

section "user-exec: hand-crafted sudo is wrapped, not skipped (U1)"
# A subagent that hand-writes its own sudo-to-a-role-user must NOT run
# un-rewritten (that was the bypass): it is wrapped like any command, so
# the inner sudo runs as the (non-sudoer) role user and fails closed.
seed_one composer
run_exec "$(payload tool_name=Bash command="sudo -n --preserve-env=PATH --set-home -u achl-reviewer -- bash -c 'rm -rf tests'" cwd="$TMPUX" agent_id=sub_c parent_tool_use_id=toolu_composer)"
WRAP_DEC=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
WRAP_CMD=$(echo "$HOOK_OUT" | "$JQ" -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$WRAP_DEC" = "allow" ] \
  && echo "$WRAP_CMD" | grep -qE '^sudo -n .*-u achl-composer -- bash -c ' \
  && echo "$WRAP_CMD" | grep -qF -- "sudo -n --preserve-env=PATH --set-home -u achl-reviewer"; then
  TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} hand-crafted sudo is wrapped by the true role (inner sudo neutralized)"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAIL_DETAILS+=("U1: expected outer -u achl-composer wrapping the inner sudo; got dec='$WRAP_DEC' cmd='${WRAP_CMD:0:180}'")
  echo "${CLR_FAIL}  ✗${CLR_RST} hand-crafted sudo not neutralized"
fi

section "user-exec: unprovisioned / unresolvable contexts stay on the session user"
seed_one probe   # achl-probe NOT in the test marker roster
assert_noop "$(payload tool_name=Bash command='ls' cwd="$TMPUX" agent_id=sub_p parent_tool_use_id=toolu_probe)" \
  "role user absent from marker roster → no rewrite"
echo "{\"toolu_a\": {\"role\": \"composer\", \"denied\": [], \"ts\": $NOW}, \"toolu_b\": {\"role\": \"reviewer-inloop\", \"denied\": [], \"ts\": $NOW}}" > "$TBL"
assert_noop "$(payload tool_name=Bash command='ls' cwd="$TMPUX" agent_id=sub_x)" \
  "ambiguous intersection (two live roles, no parent/slug) → no rewrite"
echo "{\"toolu_f\": {\"role\": \"unconfined\", \"denied\": [], \"ts\": $NOW}}" > "$TBL"
assert_noop "$(payload tool_name=Bash command='ls' cwd="$TMPUX" agent_id=sub_f)" \
  "unconfined role → no rewrite"

section "user-exec: AGENTIC_OS_USER_MODE=off disables rewriting"
seed_one composer
OFF_OUT=$(printf '%s' "$(payload tool_name=Bash command='ls' cwd="$TMPUX" agent_id=sub_c parent_tool_use_id=toolu_composer)" | AGENTIC_OS_MARKER="$MARKER" AGENTIC_OS_USER_MODE=off bash "$H" 2>/dev/null)
assert_eq "$OFF_OUT" "" "user mode off → silent allow despite marker + exact role"

section "user-exec: slug claim must be verified against the live table"
# Only reviewer-inloop live: a composer slug claim is rejected by the
# shared resolution lib, the single live role wins, and the rewrite
# targets achl-reviewer — a subagent cannot pick a laxer uid by slug.
seed_one reviewer-inloop
assert_rewrite "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-x-1-c1 open https://x' cwd="$TMPUX" agent_id=sub_s)" \
  "composer slug claim, reviewer live → rewrites to achl-reviewer (table wins)" "achl-reviewer" "playwright-cli"

section "user-exec: non-achilles project → inert"
PLAINUX=$(mktemp -d)
( cd "$PLAINUX" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
PLAIN_OUT=$(printf '%s' "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-x-1-c1 open https://x' cwd="$PLAINUX" agent_id=sub_c)" | AGENTIC_OS_MARKER="$MARKER" bash "$H" 2>/dev/null)
assert_eq "$PLAIN_OUT" "" "plain repo → no rewrite despite marker + slug"
rm -rf "$PLAINUX"

section "user-exec: slug honored only from a real playwright-cli invocation (R1)"
# Ambiguous table (two live roles) so the SLUG is what would flip
# ACTOR_EXACT and pick a uid. A -s= token in arbitrary command text must
# NOT be honored; the same slug from a real playwright-cli command is.
echo "{\"toolu_a\": {\"role\": \"composer\", \"denied\": [], \"ts\": $NOW}, \"toolu_b\": {\"role\": \"reviewer-inloop\", \"denied\": [], \"ts\": $NOW}}" > "$TBL"
assert_noop "$(payload tool_name=Bash command='git commit -m "wip -s=composer-x"' cwd="$TMPUX" agent_id=sub_g)" \
  "git commit with -s= in message, ambiguous table → no rewrite (slug ignored: not playwright-cli)"
assert_rewrite "$(payload tool_name=Bash command='npx playwright-cli -s=composer-x open https://y' cwd="$TMPUX" agent_id=sub_g)" \
  "playwright-cli -s=composer-x, ambiguous table → rewrites to achl-composer (slug honored)" "achl-composer" "playwright-cli"
