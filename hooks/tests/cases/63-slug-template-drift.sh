#!/bin/bash
# Slug-template drift pin (#16 / cross-cutting §10).
# Greps the coverage-expansion reference docs for every `-s=<literal>`
# playwright-cli slug template and runs each through
# playwright-cli-isolation-guard.sh, asserting ALLOW. This pins P3's doc
# slug fixes to the guard's regex: if a doc introduces a slug literal the
# guard would DENY, this test fails — the doc and the regex cannot drift.
H="$HOOK_DIR/playwright-cli-isolation-guard.sh"
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
COV_REF_DIR="$REPO_ROOT/skills/coverage-expansion"

assert_eq "$([ -d "$COV_REF_DIR" ] && echo present || echo missing)" "present" "coverage-expansion skill dir exists"

section "slug-template-drift: every -s= literal in coverage-expansion docs ALLOWs"
# Extract unique -s= literals. Allow the template metachars <>/ that appear
# in doc placeholders (probe-j-<slug>-<pass>); the guard tolerates them.
# Scope to ROLE-PREFIXED slug templates — the canonical forms §10 governs
# (composer-/reviewer-/probe-/phase1-/phase2-/phase4-/stage2-/cleanup-/
# companion-/fd-). A bare placeholder like `<slug>` / `<name>` is doc prose
# illustrating the slug position, not a slug literal the guard sees, so it
# is out of scope for the drift pin.
SLUG_LITERALS=$(grep -rhoE -- '-s=[A-Za-z0-9_.<>/-]+' "$COV_REF_DIR" 2>/dev/null \
  | sed 's/^-s=//' \
  | grep -E '^(phase1|phase2|phase4|stage2|composer|reviewer|probe|cleanup|companion|fd)-' \
  | sort -u)
assert_eq "$([ -n "$SLUG_LITERALS" ] && echo found || echo none)" "found" "coverage-expansion docs carry role-prefixed -s= literals to pin"
while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  PAYLOAD=$("$JQ" -n --arg c "npx playwright-cli run -s=$slug --headed" '{tool_name:"Bash", tool_input:{command:$c}}')
  assert_allow "$H" "$PAYLOAD" "doc slug literal '-s=$slug' → ALLOW (guard ↔ doc pinned)"
done <<EOF
$SLUG_LITERALS
EOF

section "slug-template-drift: the pin can fail — the guard still refuses an unprefixed slug"
assert_deny "$H" "$("$JQ" -n --arg c "npx playwright-cli run -s=j-checkout-3 --headed" '{tool_name:"Bash", tool_input:{command:$c}}')" \
  "bare j- slug → DENY (so the ALLOWs above are not vacuous)" "missing role prefix"
