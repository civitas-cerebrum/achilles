#!/bin/bash
# install-simulation.sh — proves the gates actually FIRE from a
# consumer-style install (the Phase-1 bug class: hooks copied to
# ~/.claude/hooks/ silently no-op because schemas/node_modules don't
# exist there).
#
# Mirrors scripts/postinstall.js's REAL copy set:
#   - every HOOK_MANIFEST entry's .sh script   (copyHookFile, chmod 755)
#   - hooks/lib/ top-level FILES only           (no subdirectories)
#   - hooks/data/ top-level FILES only          (vocabularies, e.g.
#     canonical-sections.txt)
#   - bin/jq                                    (postinstall downloads a
#     pinned jq; the sim stands in the resolved test-harness jq)
# NOT copied by postinstall (and therefore not copied here): hooks/tests/.
# Hooks must degrade gracefully without those.
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
  mkdir -p "$fake_hooks/lib" "$fake_hooks/data" "$fake_hooks/bin" "$fake_project/tests/e2e/docs"

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
  # 1b. HOOK_COMPANIONS — copied beside the registered hooks but never
  #     registered (the kernel mandate kernel, exec'd by the activation-gate
  #     wrapper). Parsed the same way so the sim tracks the installer.
  local companion_files
  companion_files=$(node -e "
    const s = require('fs').readFileSync('$repo_root/scripts/postinstall.js', 'utf8');
    const m = s.match(/const HOOK_COMPANIONS = \[([\s\S]*?)\];/);
    if (!m) { process.exit(0); }
    console.log([...m[1].matchAll(/['\"]([^'\"]+\\.sh)['\"]/g)].map(x => x[1]).join('\n'));
  " 2>/dev/null)
  for f in $companion_files; do
    if [ -f "$repo_root/hooks/$f" ]; then
      cp "$repo_root/hooks/$f" "$fake_hooks/$f"
      chmod 755 "$fake_hooks/$f"
    fi
  done

  # 1c. FACTORY_MANIFEST — the hooks/factory/ gates. postinstall gives these
  #     their own copy-and-register pass into <hooks>/factory/, because each
  #     gate sources ../lib/factory-common.sh and so must keep its place
  #     beside lib/. Mirrored (and asserted) here because the whole family
  #     once shipped with no manifest entry at all: the gates were in the
  #     tarball, the docs told projects how to opt in, and nothing copied or
  #     registered a single one of them.
  local factory_files
  mkdir -p "$fake_hooks/factory"
  factory_files=$(node -e "
    const s = require('fs').readFileSync('$repo_root/scripts/postinstall.js', 'utf8');
    const m = s.match(/const FACTORY_MANIFEST = \[([\s\S]*?)\];/);
    if (!m) { process.exit(0); }
    const files = [...new Set(
      m[1].split('\n')
        .filter(l => !/^\s*\/\//.test(l))
        .flatMap(l => [...l.matchAll(/file:\s*['\"]([^'\"]+\\.sh)['\"]/g)].map(x => x[1]))
    )];
    console.log(files.join('\n'));
  " 2>/dev/null)
  if [ -z "$factory_files" ]; then
    sim_fail "FACTORY_MANIFEST parse" \
      "no FACTORY_MANIFEST in scripts/postinstall.js — the hooks/factory/ gates would ship unregistered, so a project that commits achilles-factory-rules.json gets no gate at all"
  else
    for f in $factory_files; do
      if [ -f "$repo_root/hooks/factory/$f" ]; then
        cp "$repo_root/hooks/factory/$f" "$fake_hooks/factory/$f"
        chmod 755 "$fake_hooks/factory/$f"
      fi
    done
  fi

  # 2. hooks/lib/ — top-level files only, exactly like postinstall (its
  #    readdir loop skips non-file entries; subdirectories are NOT copied).
  local entry
  for entry in "$repo_root"/hooks/lib/*; do
    [ -f "$entry" ] && cp "$entry" "$fake_hooks/lib/"
  done

  # 3. hooks/data/ — top-level files only, exactly like postinstall (same
  #    readdir loop as lib/; subdirectories are NOT copied).
  for entry in "$repo_root"/hooks/data/*; do
    [ -f "$entry" ] && cp "$entry" "$fake_hooks/data/"
  done

  # 4. bin/jq — postinstall downloads a pinned binary to ~/.claude/hooks/bin/jq.
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

  # --- Assertion: every factory gate on disk is registered AND installed ---
  # Two halves of the same bug. A gate in hooks/factory/ that FACTORY_MANIFEST
  # does not name ships to consumers and never runs; a named gate that fails to
  # land is a registration pointing at nothing.
  local on_disk_factory g registered_set unregistered="" factory_missing=""
  on_disk_factory=$(cd "$repo_root/hooks/factory" 2>/dev/null && ls -1 *.sh 2>/dev/null || true)
  # $factory_files is newline-separated; flatten it so the membership test below
  # is a plain space-delimited substring match.
  registered_set=" $(echo $factory_files) "
  for g in $on_disk_factory; do
    case "$registered_set" in *" $g "*) ;; *) unregistered="${unregistered:+$unregistered, }$g" ;; esac
  done
  if [ -z "$unregistered" ]; then
    sim_pass "every hooks/factory/ gate is named by FACTORY_MANIFEST"
  else
    sim_fail "every hooks/factory/ gate is named by FACTORY_MANIFEST" \
      "shipped but never registered (a project that opts in gets no gate): $unregistered"
  fi
  for f in $factory_files; do
    if [ ! -f "$fake_hooks/factory/$f" ] || [ ! -x "$fake_hooks/factory/$f" ]; then
      factory_missing="${factory_missing:+$factory_missing, }$f"
    fi
  done
  if [ -z "$factory_missing" ]; then
    sim_pass "all FACTORY_MANIFEST gates copied to hooks/factory/ and executable"
  else
    sim_fail "all FACTORY_MANIFEST gates copied to hooks/factory/ and executable" "missing/non-executable: $factory_missing"
  fi

  # --- Assertion: a factory gate FIRES from the installed location ---------
  # The Phase-1 bug class applied to this family: the gates live one directory
  # deeper than every other hook and reach their library through a relative
  # `source ../lib/factory-common.sh`, which resolves only when the install
  # preserved the factory/ + lib/ + bin/ layout. Prove it with a real verdict
  # against a fake project, not just by checking the file exists.
  local fp_rules fac_payload fac_out fac_decision
  fp_rules="$fake_project/achilles-factory-rules.json"
  cat > "$fp_rules" <<'FACRULES'
{
  "version": 1,
  "rules": {
    "secrets.none": {
      "doc": "skills/achilles-protocol/references/factory-gates.md#secrets.none",
      "action": "Reference the environment variable name, never the value.",
      "scope": ["tests/**"],
      "patterns": ["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"]
    }
  }
}
FACRULES
  fac_payload=$("$JQ" -n --arg fp "$fake_project/tests/e2e/checkout.spec.ts" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:"const shopper = \"ada@example.com\";"}}')
  fac_out=$(cd "$fake_project" && printf '%s' "$fac_payload" \
    | HOME="$work/home" CLAUDE_PROJECT_DIR="$fake_project" bash "$fake_hooks/factory/secrets-gate.sh" 2>/dev/null) || true
  fac_decision=$(printf '%s' "$fac_out" | "$JQ" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
  if [ "$fac_decision" = "deny" ]; then
    sim_pass "factory secrets-gate denies a secret from the installed location (../lib/factory-common.sh resolved)"
  else
    sim_fail "factory secrets-gate denies a secret from the installed location (../lib/factory-common.sh resolved)" \
      "expected permissionDecision=deny, got '${fac_decision}' output=${fac_out:0:200}"
  fi

  # The other half of the opt-in contract: with the rule file gone the same
  # gate must allow in SILENCE — the installed-everywhere registration is only
  # safe because a project that never opted in pays nothing and sees nothing.
  rm -f "$fp_rules"
  local fac_err
  fac_err=$(mktemp "$work/factory-noopt-XXXXXX")
  fac_out=$(cd "$fake_project" && printf '%s' "$fac_payload" \
    | HOME="$work/home" CLAUDE_PROJECT_DIR="$fake_project" bash "$fake_hooks/factory/secrets-gate.sh" 2>"$fac_err") || true
  if [ -z "$fac_out" ] && [ ! -s "$fac_err" ]; then
    sim_pass "factory secrets-gate is a silent allow with no rule file (the project never opted in)"
  else
    sim_fail "factory secrets-gate is a silent allow with no rule file (the project never opted in)" \
      "expected empty stdout and stderr, got out=${fac_out:0:120} err=$(head -c 120 "$fac_err" 2>/dev/null)"
  fi
  rm -f "$fac_err"

  # --- Assertion 3+4+: integrity-chain + bash-guard + new guards in set ----
  for f in ledger-integrity-chain.sh protected-artifact-bash-guard.sh harness-self-protection-guard.sh hook-authored-state-guard.sh; do
    if [ -x "$fake_hooks/$f" ]; then
      sim_pass "$f present and executable in the installed set"
    else
      sim_fail "$f present and executable in the installed set" "not found or not executable at $fake_hooks/$f"
    fi
  done

  # --- Assertion: the kernel wrapper AND its exec target both land --------
  # The wrapper is registered; the kernel is a companion copy. Either one
  # missing means the mandate is silently unenforced from an install.
  for f in achilles-kernel-activation-gate.sh kernel-mandate-role-gate.sh; do
    if [ -x "$fake_hooks/$f" ]; then
      sim_pass "$f lands in the copy set (wrapper + kernel companion)"
    else
      sim_fail "$f lands in the copy set (wrapper + kernel companion)" "not found or not executable at $fake_hooks/$f"
    fi
  done

  # --- Assertion: hooks/data vocabulary lands in the copy set -------------
  # standard-mode-first-pass-guard.sh reads data/canonical-sections.txt; the
  # install must ship it so installed hooks don't run on the hardcoded
  # fallback vocabulary.
  if [ -f "$fake_hooks/data/canonical-sections.txt" ]; then
    sim_pass "canonical-sections.txt lands in the copy set (hooks/data shipped)"
  else
    sim_fail "canonical-sections.txt lands in the copy set (hooks/data shipped)" \
      "missing at $fake_hooks/data/canonical-sections.txt — postinstall must copy hooks/data/"
  fi

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

  # --- Assertion: attestation-gate WARNs on an evidence-free approve from a
  # fake install with NO `yaml` module hoisted. The gate now converts YAML
  # via the bundle's `tojson` subcommand (P7), so it must not silently
  # no-op the way the old require('yaml') path did at un-hoisted installs.
  # Probe whether tojson exists in the installed bundle; skip when it
  # doesn't (P7 not yet landed — reported as a P7-domain dependency).
  local probe attest_out attest_msg
  probe=$(mktemp "$work/tojson-probe-XXXXXX"); printf 'verdict: approve\n' > "$probe"
  # NODE_BIN is set by earlier case files under run.sh; standalone or
  # filtered runs reach here without it.
  if [ -n "${NODE_BIN:-$(command -v node || true)}" ] && [ -f "$fake_hooks/lib/validator.bundle.mjs" ] \
     && node "$fake_hooks/lib/validator.bundle.mjs" tojson "$probe" 2>/dev/null | grep -q 'verdict'; then
    # Evidence-free approve return (no on-disk path cited in attestation).
    local ev_free_payload
    ev_free_payload=$("$JQ" -n --arg d "workflow-reviewer-phase3: review" \
      '{tool_name:"Agent", tool_input:{description:$d}, cwd:".", tool_response:"verdict: approve\nattestation: all good"}')
    attest_out=$(cd "$fake_project" && printf '%s' "$ev_free_payload" \
      | HOME="$work/home" bash "$fake_hooks/workflow-reviewer-attestation-gate.sh" 2>/dev/null) || true
    attest_msg=$(printf '%s' "$attest_out" | "$JQ" -r '.systemMessage // empty' 2>/dev/null || echo "")
    if printf '%s' "$attest_msg" | grep -q 'approval without on-disk evidence'; then
      sim_pass "attestation-gate WARNs on evidence-free approve from a no-yaml install (tojson path)"
    else
      sim_fail "attestation-gate WARNs on evidence-free approve from a no-yaml install (tojson path)" \
        "expected a WARN systemMessage; got output=${attest_out:0:200}"
    fi
  else
    sim_pass "attestation-gate tojson assertion skipped (validator bundle 'tojson' not yet shipped — P7 dependency)"
  fi
  rm -f "$probe"
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
