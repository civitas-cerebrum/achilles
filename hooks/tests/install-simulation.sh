#!/bin/bash
# install-simulation.sh — proves the gates actually FIRE from a
# consumer-style install (the Phase-1 bug class: hooks copied to
# ~/.claude/hooks/ silently no-op because schemas/node_modules don't
# exist there).
#
# Mirrors scripts/postinstall.js's REAL copy set:
#   - every HOOK_MANIFEST entry's .sh script   (copyHookFile, chmod 755)
#   - hooks/lib/ top-level FILES only           (no subdirectories)
#   - bin/jq                                    (postinstall downloads a
#     pinned jq; the sim stands in the resolved test-harness jq)
# NOT copied by postinstall (and therefore not copied here): hooks/data/,
# hooks/tests/. Hooks must degrade gracefully without those.
#
# NOTE: this MIRRORS postinstall's copy set (does not execute postinstall.js
# itself — the installer's own copyHookFile/mtime logic is out of scope here).
#
# Everything runs against temp dirs only — never touches ~/.claude.
#
# Dual-mode:
#   - sourced by run.sh after the cases loop (shares the lib.sh counters
#     so the assertions land in the final tally), or
#   - run standalone: bash hooks/tests/install-simulation.sh

set -uo pipefail

# Standalone invocation: bootstrap lib.sh for $JQ + counters + colours.
if [ -z "${TESTS_RUN+x}" ]; then
  # shellcheck source=lib.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
  INSTALL_SIM_STANDALONE=1
else
  INSTALL_SIM_STANDALONE=0
fi

INSTALL_SIM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Counter idiom matches lib.sh's assert_* helpers so run.sh's summary
# picks these up unchanged.
sim_pass() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} install-sim: $1"
}
sim_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("install-sim: $1: $2")
  echo "${CLR_FAIL}  ✗${CLR_RST} install-sim: $1 ${CLR_DIM}(${2:0:160})${CLR_RST}"
}

run_install_simulation() {
  local repo_root="$INSTALL_SIM_REPO_ROOT"
  local work fake_hooks fake_project errfile
  work=$(mktemp -d /tmp/achilles-install-sim-XXXXXX)
  errfile=$(mktemp /tmp/achilles-install-sim-err-XXXXXX)
  # Capture paths into non-local vars so the EXIT trap can see them even when
  # the function has already returned (local vars go out of scope at return).
  _SIM_WORK="$work"; _SIM_ERRFILE="$errfile"
  trap 'rm -rf "$_SIM_WORK" "$_SIM_ERRFILE"' EXIT
  fake_hooks="$work/home/.claude/hooks"
  fake_project="$work/project"
  mkdir -p "$fake_hooks/lib" "$fake_hooks/bin" "$fake_project/tests/e2e/docs"

  # --- Mirror the postinstall copy set ------------------------------------
  # 1. Hook scripts: exactly the HOOK_MANIFEST entries, parsed live from
  #    postinstall.js so the sim never drifts from the real installer.
  # Parse the literal HOOK_MANIFEST array from postinstall.js using Node so
  # the sim never drifts from the real installer. Node is guaranteed (the
  # suite builds the validator with it). Matches file: '...' / file: "..."
  # entries, strips lines whose non-whitespace content starts with //, and
  # deduplicates via Set — exactly mirroring what postinstall installs.
  local manifest_files f
  manifest_files=$(node -e "
    const s = require('fs').readFileSync('$repo_root/scripts/postinstall.js', 'utf8');
    const m = s.match(/const HOOK_MANIFEST = \[([\s\S]*?)\];/);
    if (!m) { process.exit(1); }
    const lines = m[1].split('\n');
    const files = [...new Set(
      lines
        .filter(l => !/^\s*\/\//.test(l))
        .flatMap(l => [...l.matchAll(/file:\s*['\"]([^'\"]+\\.sh)['\"]/g)].map(x => x[1]))
    )];
    console.log(files.join('\n'));
  " 2>/dev/null)
  if [ -z "$manifest_files" ]; then
    sim_fail "manifest parse" "could not extract HOOK_MANIFEST file list from scripts/postinstall.js"
    return
  fi
  for f in $manifest_files; do
    if [ -f "$repo_root/hooks/$f" ]; then
      cp "$repo_root/hooks/$f" "$fake_hooks/$f"
      chmod 755 "$fake_hooks/$f"   # postinstall: fs.chmodSync(hookDest, 0o755)
    fi
  done

  # 2. hooks/lib/ — top-level files only, exactly like postinstall (its
  #    readdir loop skips non-file entries; subdirectories are NOT copied).
  local entry
  for entry in "$repo_root"/hooks/lib/*; do
    [ -f "$entry" ] && cp "$entry" "$fake_hooks/lib/"
  done

  # 3. bin/jq — postinstall downloads a pinned binary to ~/.claude/hooks/bin/jq.
  #    Use the repo-bundled binary when present; otherwise symlink the jq the
  #    test harness resolved. (Symlink, not copy: macOS SIGKILLs copies of
  #    signed platform binaries like /usr/bin/jq.) Either way the hooks'
  #    bundled-jq-first resolution path is exercised.
  if [ -x "$repo_root/hooks/bin/jq" ]; then
    cp "$repo_root/hooks/bin/jq" "$fake_hooks/bin/jq" && chmod 755 "$fake_hooks/bin/jq"
  else
    ln -s "$JQ" "$fake_hooks/bin/jq"
  fi

  # --- Assertion 1: the validator bundle is part of the copy set ----------
  if [ -f "$fake_hooks/lib/validator.bundle.mjs" ]; then
    sim_pass "validator.bundle.mjs lands in the copy set"
  else
    sim_fail "validator.bundle.mjs lands in the copy set" \
      "validator.bundle.mjs missing from hooks/lib (run npm run build:validator before testing; ship it in the tarball)"
  fi

  # --- Assertion 2: every manifest hook copied and executable -------------
  local missing=""
  for f in $manifest_files; do
    if [ ! -f "$fake_hooks/$f" ] || [ ! -x "$fake_hooks/$f" ]; then
      missing="${missing:+$missing, }$f"
    fi
  done
  if [ -z "$missing" ]; then
    sim_pass "all HOOK_MANIFEST scripts copied and executable"
  else
    sim_fail "all HOOK_MANIFEST scripts copied and executable" "missing/non-executable: $missing"
  fi

  # --- Assertion 3+4: integrity-chain + bash-guard in the copy set --------
  for f in ledger-integrity-chain.sh protected-artifact-bash-guard.sh; do
    if [ -x "$fake_hooks/$f" ]; then
      sim_pass "$f present and executable in the installed set"
    else
      sim_fail "$f present and executable in the installed set" "not found or not executable at $fake_hooks/$f"
    fi
  done

  # --- Assertion 5+6: write-gate DENIES a schema-invalid ledger write -----
  # Run from the fake project (no repo, no schemas/ dir anywhere above) with
  # HOME pointed at the fake home — exactly a consumer's runtime context.
  local ledger_path payload out decision
  ledger_path="$fake_project/tests/e2e/docs/onboarding-status.json"
  payload=$("$JQ" -n --arg fp "$ledger_path" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:"{\"currentPhase\": \"not-a-number\"}"}}')
  out=$(cd "$fake_project" && printf '%s' "$payload" \
    | HOME="$work/home" bash "$fake_hooks/onboarding-ledger-write-gate.sh" 2>/dev/null) || true
  decision=$(printf '%s' "$out" | "$JQ" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
  if [ "$decision" = "deny" ]; then
    sim_pass "write-gate denies schema-invalid ledger from the installed location"
  else
    sim_fail "write-gate denies schema-invalid ledger from the installed location" \
      "expected permissionDecision=deny, got '${decision}' output=${out:0:200}"
  fi
  # The deny must be a REAL schema verdict (validator bundle ran), not the
  # parse-fail or skipped-validation fallback path.
  if printf '%s' "$out" | grep -q 'fails schema validation'; then
    sim_pass "write-gate deny is a real schema verdict (bundle executed)"
  else
    sim_fail "write-gate deny is a real schema verdict (bundle executed)" \
      "deny reason does not cite schema validation — bundle likely skipped. output=${out:0:200}"
  fi

  # --- Assertion 7+8: return-schema guard yields a REAL validation verdict
  # (not a module-not-found warning) from the installed location.
  local ret_payload guard_out guard_err
  ret_payload=$("$JQ" -n --arg d "composer-j-login: compose tests" \
    '{tool_name:"Agent", tool_input:{description:$d}, tool_response:"status: not-a-valid-composer-return"}')
  guard_out=$(cd "$fake_project" && printf '%s' "$ret_payload" \
    | HOME="$work/home" bash "$fake_hooks/subagent-return-schema-guard.sh" 2>"$errfile") || true
  guard_err=$(cat "$errfile" 2>/dev/null || true)
  # A real verdict carries the validator's SCHEMA_FAIL lines / schema-error
  # header AND is not the bundle-missing fallback message.
  if printf '%s' "$guard_out" | grep -q 'SCHEMA_FAIL\|Schema validation' \
     && ! printf '%s' "$guard_out" | grep -q 'validator bundle missing'; then
    sim_pass "return guard produces a real validation verdict when installed"
  else
    sim_fail "return guard produces a real validation verdict when installed" \
      "no real SCHEMA_FAIL verdict in output (or bundle-missing fallback hit). out=${guard_out:0:200} err=${guard_err:0:200}"
  fi
  if printf '%s\n%s' "$guard_out" "$guard_err" | grep -qi 'ERR_MODULE_NOT_FOUND\|Cannot find'; then
    sim_fail "return guard has no unresolved module deps when installed" \
      "module-resolution error leaked. out=${guard_out:0:200} err=${guard_err:0:200}"
  else
    sim_pass "return guard has no unresolved module deps when installed"
  fi
}

run_install_simulation

# Standalone summary (run.sh prints its own).
if [ "$INSTALL_SIM_STANDALONE" = "1" ]; then
  echo
  if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "${CLR_PASS}✓ install simulation: all ${TESTS_RUN} assertions passed — gates fire from a consumer-style install${CLR_RST}"
    exit 0
  else
    echo "${CLR_FAIL}✗ install simulation: ${TESTS_FAILED} of ${TESTS_RUN} assertions failed${CLR_RST}"
    for d in "${FAIL_DETAILS[@]}"; do echo "  - $d"; done
    exit 1
  fi
fi
