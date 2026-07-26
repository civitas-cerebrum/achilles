#!/bin/bash
# Tests for scripts/agentic-os/provision-role-users.sh — dry-run contract.
# The provisioner is operator-run (root, Linux); tests exercise --dry-run
# only, asserting the generated roster/tiers/sudoers/marker/ACL plan so
# the script can never drift from hooks/lib/agent-role-privileges.sh.
PROV="$HOOK_DIR/../scripts/agentic-os/provision-role-users.sh"
# In the installed layout the script ships under the package's scripts/;
# in-repo the path above resolves. Skip cleanly if absent (installed-set
# tests are covered by install-simulation.sh's manifest sweep).
if [ ! -f "$PROV" ]; then
  PROV="$(dirname "$HOOK_DIR")/scripts/agentic-os/provision-role-users.sh"
fi

section "provision-role-users: dry-run provision plan"
DRY_OUT=$(bash "$PROV" provision --session-user testuser --project /srv/app --dry-run 2>&1)
DRY_EC=$?
assert_eq "$DRY_EC" "0" "dry-run provision exits 0 as non-root"

check_contains() {
  local substr="$1" name="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$DRY_OUT" | grep -qF -- "$substr"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} ${name}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAIL_DETAILS+=("${name}: dry-run output missing '${substr}'")
    echo "${CLR_FAIL}  ✗${CLR_RST} ${name} ${CLR_DIM}(missing '${substr}')${CLR_RST}"
  fi
}

check_contains "groupadd --system achl-agents" "creates achl-agents group"
check_contains "groupadd --system achl-write"  "creates achl-write tier group"
check_contains "groupadd --system achl-read"   "creates achl-read tier group"
# Tier derivation from the role map: composer (mutate-privileged) → write
# tier; reviewer family (mutate-denied) → read tier.
check_contains "-G achl-write achl-composer"   "composer user lands in the write tier"
check_contains "-G achl-read achl-reviewer"    "reviewer user lands in the read tier"
check_contains "-G achl-read achl-wfreviewer"  "workflow-reviewer user lands in the read tier"
check_contains "-G achl-write achl-cleanup"    "cleanup user keeps write tier (mutate not denied)"
check_contains "-s /usr/sbin/nologin"          "role users get nologin shells"
check_contains "/etc/sudoers.d/achilles-agentic-os" "writes the sudoers drop-in"
check_contains "testuser ALL=(" "sudoers grants runas to the session user only"
check_contains "NOPASSWD: ALL" "sudoers is NOPASSWD (non-interactive harness)"
check_contains "/etc/achilles-agentic-os/enabled" "writes the enablement marker"
check_contains "g:achl-agents:rX" "baseline read+traverse ACL for all agents"
check_contains "g:achl-write:rwX" "write-tier rwX ACL on working surfaces"
check_contains "/srv/app/tests" "ACLs applied to the given project"
check_contains "g:achl-write:r-- -m g:achl-read:r-- /srv/app/tests/e2e/docs/onboarding-status.json" \
  "ledger pinned read-only for both tiers"
check_contains "/srv/app/.achilles/.agent-process-table.json" "process table pinned read-only"

section "provision-role-users: roster mirrors the role map"
# Every role's OS user must appear in the dry-run plan — drift guard
# against list_privilege_roles/role_os_user edits without provisioner runs.
. "$HOOK_DIR/lib/agent-role-privileges.sh"
ALL_PRESENT=1
for role in $(list_privilege_roles); do
  u=$(role_os_user "$role")
  echo "$DRY_OUT" | grep -qF -- "$u" || { ALL_PRESENT=0; echo "  missing: $u ($role)"; }
done
assert_eq "$ALL_PRESENT" "1" "every mapped role user appears in the provision plan"

section "provision-role-users: dry-run deprovision + argument validation"
DEP_OUT=$(bash "$PROV" deprovision --dry-run 2>&1)
assert_eq "$?" "0" "dry-run deprovision exits 0"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$DEP_OUT" | grep -q "userdel achl-composer" && echo "$DEP_OUT" | grep -q "groupdel achl-agents"; then
  TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} deprovision plan removes users and groups"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAIL_DETAILS+=("deprovision plan incomplete"); echo "${CLR_FAIL}  ✗${CLR_RST} deprovision plan removes users and groups"
fi
NOUSER_EC=0
bash "$PROV" provision --dry-run >/dev/null 2>&1 || NOUSER_EC=$?
assert_eq "$NOUSER_EC" "1" "provision without --session-user fails"
USAGE_EC=0
bash "$PROV" bogus-action >/dev/null 2>&1 || USAGE_EC=$?
assert_eq "$USAGE_EC" "1" "unknown action prints usage and fails"
