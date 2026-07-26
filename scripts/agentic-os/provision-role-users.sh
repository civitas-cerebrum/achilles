#!/bin/bash
# provision-role-users.sh — operator-run provisioner for the agentic-OS
#                           role-bound user layer.
#
# Creates one `achl-*` system user per harness role (roster generated
# from hooks/lib/agent-role-privileges.sh so it can never drift from the
# role map), tiered groups, a scoped NOPASSWD sudoers drop-in for the
# session user, filesystem ACLs on the project, and the enablement
# marker that hooks/agentic-user-exec.sh keys on. After provisioning,
# every Bash command a dispatched subagent runs executes under its
# role's OS user — privileges become kernel-enforced.
#
# Usage (run as root):
#   provision-role-users.sh provision --session-user <user> [--project <dir>] [--dry-run]
#   provision-role-users.sh deprovision [--dry-run]
#   provision-role-users.sh status
#
#   --session-user  The account Claude Code runs as (the only account the
#                   sudoers drop-in lets impersonate the role users).
#   --project       Project root to apply tiered ACLs to (repeatable via
#                   re-runs; provisioning is idempotent).
#   --dry-run       Print every mutating command / file body instead of
#                   executing. Safe as non-root.
#
# Layout created
# --------------
#   groups : achl-agents (read+traverse on the project)
#            achl-write  (rwX on working surfaces: tests/, .git/,
#                         test-results/, playwright-report/,
#                         .playwright-cli/, node_modules/)
#            achl-read   (no grants beyond achl-agents — the verifier tier)
#   users  : achl-<role> — system accounts, nologin shell, homes under
#            /var/lib/achilles/<user> (for sudo --set-home), tier group
#            membership derived from role_os_tier (mutate-denied roles →
#            achl-read; kernel can never be laxer than the hook policy).
#   sudoers: /etc/sudoers.d/achilles-agentic-os — <session-user> may run
#            ALL as the achl-* users, NOPASSWD, with PATH/TMPDIR/
#            PLAYWRIGHT_* kept. Validated with visudo -cf when available.
#   marker : /etc/achilles-agentic-os/enabled — one provisioned user per
#            line; agentic-user-exec.sh refuses to rewrite to any user
#            not listed here.
#   ACLs   : protected pipeline artifacts (ledgers, journey map, approver
#            registry, integrity sidecar, findings ledger, process table)
#            are pinned r-- for BOTH tiers — no role user can mutate them
#            by any command shape; the sanctioned Write/Edit paths run as
#            the session user and are unaffected.
#
# Linux-only (useradd/groupadd/setfacl). On other platforms the script
# exits 1 with a message; the hook layer remains the enforcement floor.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md §"OS-user
# execution mode"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../hooks/lib/agent-role-privileges.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../hooks/lib/agent-role-privileges.sh"

SUDOERS_FILE="/etc/sudoers.d/achilles-agentic-os"
MARKER_DIR="/etc/achilles-agentic-os"
MARKER_FILE="$MARKER_DIR/enabled"
HOME_BASE="/var/lib/achilles"
GROUP_ALL="achl-agents"
GROUP_WRITE="achl-write"
GROUP_READ="achl-read"

DRY=0
ACTION="${1:-}"
shift || true
SESSION_USER=""
PROJECT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-user) SESSION_USER="${2:-}"; shift 2 ;;
    --project)      PROJECT_DIR="${2:-}"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

run() {
  if [ "$DRY" = "1" ]; then
    echo "+ $*"
  else
    "$@"
  fi
}

write_file() {
  # write_file <path> <mode> — body on stdin.
  local path="$1" mode="$2" body
  body=$(cat)
  if [ "$DRY" = "1" ]; then
    echo "+ write $path (mode $mode):"
    echo "$body" | sed 's/^/    /'
  else
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$body" > "$path"
    chmod "$mode" "$path"
  fi
}

require_linux() {
  # Dry-run is allowed anywhere (prints the Linux plan); real runs are
  # Linux-only.
  [ "$DRY" = "1" ] && return 0
  if [ "$(uname -s)" != "Linux" ]; then
    echo "provision-role-users.sh: Linux-only (useradd/groupadd/setfacl). On this platform the hook-layer guard remains the enforcement floor." >&2
    exit 1
  fi
}

require_root() {
  if [ "$DRY" != "1" ] && [ "$(id -u)" != "0" ]; then
    echo "provision-role-users.sh: must run as root (or use --dry-run)." >&2
    exit 1
  fi
}

all_role_users() {
  local role
  for role in $(list_privilege_roles); do
    role_os_user "$role"
  done
}

do_provision() {
  require_linux
  require_root
  if [ -z "$SESSION_USER" ]; then
    echo "provision-role-users.sh: --session-user <user> is required for provision." >&2
    exit 1
  fi

  # Groups (idempotent).
  local g
  for g in "$GROUP_ALL" "$GROUP_WRITE" "$GROUP_READ"; do
    if [ "$DRY" = "1" ] || ! getent group "$g" >/dev/null 2>&1; then
      run groupadd --system "$g"
    fi
  done

  # Role users (idempotent), tier membership from the role map.
  local role user tier tier_group
  for role in $(list_privilege_roles); do
    user=$(role_os_user "$role")
    tier=$(role_os_tier "$role")
    tier_group="$GROUP_WRITE"; [ "$tier" = "read" ] && tier_group="$GROUP_READ"
    if [ "$DRY" = "1" ] || ! id "$user" >/dev/null 2>&1; then
      run useradd --system -M -s /usr/sbin/nologin \
        -d "$HOME_BASE/$user" -g "$GROUP_ALL" -G "$tier_group" "$user"
    else
      run usermod -g "$GROUP_ALL" -G "$tier_group" "$user"
    fi
    run mkdir -p "$HOME_BASE/$user"
    run chown "$user:$GROUP_ALL" "$HOME_BASE/$user"
    run chmod 0750 "$HOME_BASE/$user"
  done

  # Sudoers drop-in: the session user may impersonate ONLY the role users.
  local runas
  runas=$(all_role_users | paste -sd, -)
  write_file "$SUDOERS_FILE" 0440 <<SUDOERS
# achilles agentic-OS role-bound users — generated by provision-role-users.sh
# ${SESSION_USER} may execute commands as the achl-* role users only.
Defaults:${SESSION_USER} env_keep += "PATH TMPDIR PLAYWRIGHT_BROWSERS_PATH PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"
${SESSION_USER} ALL=(${runas}) NOPASSWD: ALL
SUDOERS
  if [ "$DRY" != "1" ] && command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "$SUDOERS_FILE"; then
      rm -f "$SUDOERS_FILE"
      echo "provision-role-users.sh: sudoers validation failed; drop-in removed." >&2
      exit 1
    fi
  fi

  # Enablement marker — agentic-user-exec.sh keys on this roster.
  write_file "$MARKER_FILE" 0444 <<MARKER
$(all_role_users)
MARKER

  # Project ACLs.
  if [ -n "$PROJECT_DIR" ]; then
    apply_project_acls "$PROJECT_DIR"
  fi

  echo "agentic-OS role users provisioned. Restart Claude Code; subagent Bash now executes under achl-* users."
}

apply_project_acls() {
  local proj="$1"
  if [ "$DRY" != "1" ] && ! command -v setfacl >/dev/null 2>&1; then
    echo "provision-role-users.sh: setfacl not found — skipping project ACLs (install the 'acl' package and re-run)." >&2
    return 0
  fi

  # Baseline: all agents read+traverse the project (current + default ACL).
  run setfacl -R -m "g:$GROUP_ALL:rX" -m "d:g:$GROUP_ALL:rX" "$proj"

  # Write tier: rwX on the working surfaces only.
  local d
  for d in tests .git test-results playwright-report .playwright-cli node_modules; do
    if [ "$DRY" = "1" ] || [ -d "$proj/$d" ]; then
      run setfacl -R -m "g:$GROUP_WRITE:rwX" -m "d:g:$GROUP_WRITE:rwX" "$proj/$d"
    fi
  done

  # Protected pipeline artifacts: pinned read-only for BOTH tiers. The
  # sanctioned mutation paths (Write/Edit tools + hooks) run as the
  # session user and are unaffected. Roster mirrors
  # protected-artifact-bash-guard.sh's PROTECTED list.
  local f
  for f in \
    tests/e2e/docs/onboarding-status.json \
    tests/e2e/docs/journey-map.md \
    tests/e2e/docs/.phase4-cycle-state.json \
    tests/e2e/docs/coverage-expansion-state.json \
    tests/e2e/docs/.workflow-approvers.json \
    tests/e2e/docs/.ledger-integrity.json \
    tests/e2e/docs/adversarial-findings.md \
    tests/e2e/docs/flake-quarantine.md \
    tests/perf/docs/perf-onboarding-status.json \
    tests/perf/docs/.workflow-approvers.json \
    tests/perf/docs/.ledger-integrity.json \
    .achilles/.agent-process-table.json; do
    if [ "$DRY" = "1" ] || [ -f "$proj/$f" ]; then
      run setfacl -m "g:$GROUP_WRITE:r--" -m "g:$GROUP_READ:r--" "$proj/$f"
    fi
  done
}

do_deprovision() {
  require_linux
  require_root
  run rm -f "$SUDOERS_FILE"
  run rm -f "$MARKER_FILE"
  local user
  for user in $(all_role_users); do
    if [ "$DRY" = "1" ] || id "$user" >/dev/null 2>&1; then
      run userdel "$user"
      run rm -rf "${HOME_BASE:?}/${user:?}"
    fi
  done
  local g
  for g in "$GROUP_WRITE" "$GROUP_READ" "$GROUP_ALL"; do
    if [ "$DRY" = "1" ] || getent group "$g" >/dev/null 2>&1; then
      run groupdel "$g"
    fi
  done
  echo "agentic-OS role users deprovisioned. Project ACLs are left in place; remove with 'setfacl -R -b <project>' if desired."
}

do_status() {
  if [ -f "$MARKER_FILE" ]; then
    echo "enabled — provisioned role users:"
    cat "$MARKER_FILE"
  else
    echo "disabled — no marker at $MARKER_FILE (hook-layer enforcement only)."
  fi
}

case "$ACTION" in
  provision)   do_provision ;;
  deprovision) do_deprovision ;;
  status)      do_status ;;
  *)
    echo "usage: provision-role-users.sh provision --session-user <user> [--project <dir>] [--dry-run]" >&2
    echo "       provision-role-users.sh deprovision [--dry-run]" >&2
    echo "       provision-role-users.sh status" >&2
    exit 1
    ;;
esac
