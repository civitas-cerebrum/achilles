#!/bin/bash
# install-simulation.sh — proves the gates actually FIRE from a
# consumer-style install (hooks copied to ~/.claude/hooks/ silently
# no-op when schemas/node_modules don't exist there).
#
# Mirrors scripts/postinstall.js's REAL copy set:
#   - every hook-manifest.json hook + companion (copyHookFile, chmod 755)
#   - every manifest.factory gate into factory/ (beside lib/)
#   - hooks/lib/ top-level FILES only           (no subdirectories)
#   - hooks/data/ top-level FILES only          (vocabularies, e.g.
#     canonical-sections.txt)
#   - bin/jq                                    (postinstall downloads a
#     pinned jq; the sim stands in the resolved test-harness jq)
# NOT copied by postinstall (and therefore not copied here): hooks/tests/.
# Hooks must degrade gracefully without those.
#
# The copy set is MIRRORED, not executed; only the upgrade-path assertion
# runs the installer (installCivitasHooks into a temp .claude/).
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
  # 1. Hook scripts: every registered hook and every companion (copied beside
  #    the registered hooks, never registered — the kernel, exec'd by the
  #    activation-gate wrapper), read from the manifest the installer reads.
  local manifest="$repo_root/hooks/data/hook-manifest.json" manifest_files companion_files f
  manifest_files=$("$JQ" -r '[.hooks[].file] | unique | .[]' "$manifest" 2>/dev/null)
  companion_files=$("$JQ" -r '.companions[]' "$manifest" 2>/dev/null)
  if [ -z "$manifest_files" ] || [ -z "$companion_files" ]; then
    sim_fail "manifest parse" "could not read .hooks[].file / .companions[] from $manifest"
    return
  fi
  for f in $manifest_files $companion_files; do
    if [ -f "$repo_root/hooks/$f" ]; then
      cp "$repo_root/hooks/$f" "$fake_hooks/$f"
      chmod 755 "$fake_hooks/$f"   # postinstall: fs.chmodSync(hookDest, 0o755)
    fi
  done

  # 1c. manifest.factory — the hooks/factory/ gates, copied into
  #     <hooks>/factory/ because each sources ../lib/factory-common.sh.
  local factory_files
  mkdir -p "$fake_hooks/factory"
  factory_files=$("$JQ" -r '[.factory[].file] | unique | .[]' "$manifest" 2>/dev/null)
  if [ -z "$factory_files" ]; then
    sim_fail "manifest.factory parse" \
      "no .factory[] in $manifest — the hooks/factory/ gates would ship unregistered"
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

  if [ -f "$fake_hooks/lib/babel-parser.bundle.js" ]; then
    sim_pass "babel-parser.bundle.js lands in the copy set"
  else
    sim_fail "babel-parser.bundle.js lands in the copy set" \
      "babel-parser.bundle.js missing from hooks/lib (run npm run build:validator before testing; ship it in the tarball)"
  fi

  # --- Assertion 2: every manifest hook copied and executable -------------
  local missing=""
  for f in $manifest_files; do
    if [ ! -f "$fake_hooks/$f" ] || [ ! -x "$fake_hooks/$f" ]; then
      missing="${missing:+$missing, }$f"
    fi
  done
  if [ -z "$missing" ]; then
    sim_pass "all manifest hook scripts copied and executable"
  else
    sim_fail "all manifest hook scripts copied and executable" "missing/non-executable: $missing"
  fi

  # --- Assertion: every registered factory gate lands, executable (lint factory-manifest holds disk <-> manifest) ---
  local factory_missing=""
  for f in $factory_files; do
    if [ ! -f "$fake_hooks/factory/$f" ] || [ ! -x "$fake_hooks/factory/$f" ]; then
      factory_missing="${factory_missing:+$factory_missing, }$f"
    fi
  done
  if [ -z "$factory_missing" ]; then
    sim_pass "all manifest.factory gates copied to hooks/factory/ and executable"
  else
    sim_fail "all manifest.factory gates copied to hooks/factory/ and executable" "missing/non-executable: $factory_missing"
  fi

  # --- Assertion: a factory gate FIRES from the installed location ---------
  # The gates live one directory deeper than every other hook and reach their library through a relative
  # `source ../lib/factory-common.sh`, which resolves only when the install preserved the factory/ + lib/ + bin/
  # layout. Prove it with a real verdict against a fake project, not by checking that the file exists.
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

  # The other half of the opt-in contract: with the rule file gone each gate
  # must allow in SILENCE — the installed-everywhere registration is only
  # safe because a project that never opted in pays nothing and sees nothing.
  # One Write-matcher gate and one Bash-matcher gate.
  rm -f "$fp_rules"
  local fac_err fac_gate fac_in
  fac_err=$(mktemp "$work/factory-noopt-XXXXXX")
  for fac_gate in secrets-gate commit-gate; do
    if [ "$fac_gate" = commit-gate ]; then
      fac_in=$("$JQ" -n '{tool_name:"Bash", tool_input:{command:"git commit -m x"}}')
    else
      fac_in="$fac_payload"
    fi
    fac_out=$(cd "$fake_project" && printf '%s' "$fac_in" \
      | HOME="$work/home" CLAUDE_PROJECT_DIR="$fake_project" bash "$fake_hooks/factory/$fac_gate.sh" 2>"$fac_err") || true
    if [ -z "$fac_out" ] && [ ! -s "$fac_err" ]; then
      sim_pass "factory $fac_gate is a silent allow with no rule file (the project never opted in)"
    else
      sim_fail "factory $fac_gate is a silent allow with no rule file (the project never opted in)" \
        "expected empty stdout and stderr, got out=${fac_out:0:120} err=$(head -c 120 "$fac_err" 2>/dev/null)"
    fi
  done
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

  # --- Assertion: upgrade path leaves settings.json unchanged -------------
  # The fixture is the settings.json the pre-split installer wrote (hooks dir
  # as @HOOKS@). Re-running the installer over it must change nothing except
  # adding the factory gates, which that installer did not register.
  local up="$work/upgrade" fixture="$repo_root/hooks/tests/fixtures/settings-0.1.8-pre-split.json" up_diff
  mkdir -p "$up/.claude"
  sed "s#@HOOKS@#$up/.claude/hooks#g" "$fixture" > "$up/.claude/settings.json"
  cp "$up/.claude/settings.json" "$work/settings-expected.json"
  HOME="$up" CIVITAS_SKIP_JQ_INSTALL=1 node -e "require('$repo_root/scripts/postinstall.js').installCivitasHooks('$up/.claude')" >/dev/null 2>&1
  up_diff=$(diff <("$JQ" -S . "$work/settings-expected.json") \
    <("$JQ" -S '.hooks |= map_values(map(.hooks |= map(select(.command | contains("/hooks/factory/") | not))) | map(select(.hooks | length > 0)))' "$up/.claude/settings.json") 2>&1)
  if [ -z "$up_diff" ]; then
    sim_pass "re-install over the pre-split settings.json leaves it unchanged"
  else
    sim_fail "re-install over the pre-split settings.json leaves it unchanged" "$up_diff"
  fi

  # What the upgrade added: exactly manifest.factory, one registration each.
  local factory_want factory_have
  factory_want=$("$JQ" -r '.factory[] | "\(.event) \(.matcher) \(.file)"' "$manifest" | sort)
  factory_have=$("$JQ" -r '.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m
    | .hooks[] | select(.command | contains("/hooks/factory/"))
    | "\($e) \($m) \(.command | split("/") | last)"' "$up/.claude/settings.json" | sort)
  if [ "$factory_want" = "$factory_have" ]; then
    sim_pass "re-install registers exactly manifest.factory (event, matcher, file; once each)"
  else
    sim_fail "re-install registers exactly manifest.factory (event, matcher, file; once each)" \
      "$(diff <(echo "$factory_want") <(echo "$factory_have"))"
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
  local attest_out attest_msg ev_free_payload
  if ! command -v node >/dev/null 2>&1; then
    sim_fail "attestation-gate WARNs on evidence-free approve from a no-yaml install (tojson path)" "required tool 'node' missing"
    return
  fi
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
}

# A throwaway copy of the package (installer, hooks without their tests, package.json).
sim_make_package() {
  local dir="$1" repo_root="$INSTALL_SIM_REPO_ROOT"
  mkdir -p "$dir/hooks"
  cp -R "$repo_root/scripts" "$repo_root/package.json" "$dir/"
  cp -R "$repo_root"/hooks/* "$dir/hooks/"
  rm -rf "$dir/hooks/tests"
}

# Upgrade path, driven through the real installer against a package copy whose
# files carry the 1985 mtimes an npm tarball has.
run_upgrade_simulation() {
  local repo_root="$INSTALL_SIM_REPO_ROOT" work pkg claude
  work=$(mktemp -d /tmp/achilles-upgrade-sim-XXXXXX)
  _SIM_UPGRADE_WORK="$work"
  trap 'rm -rf "$_SIM_WORK" "$_SIM_ERRFILE" "$_SIM_UPGRADE_WORK"' EXIT
  pkg="$work/pkg"; claude="$work/project/.claude"
  mkdir -p "$work/project"
  sim_make_package "$pkg"
  echo "# retired" > "$pkg/hooks/lib/retired-helper.sh"
  find "$pkg" -exec touch -t 198501010000 {} +
  sim_install() {
    HOME="$work/home" CIVITAS_SKIP_JQ_INSTALL=1 node -e "require('$1/scripts/postinstall.js').installCivitasHooks('$claude')" 2>&1
  }
  local out gate="$claude/hooks/commit-message-gate.sh"

  # A 0.1.8 install left a hook behind and no record: the first recorded install replaces it and says how many.
  mkdir -p "$claude/hooks"; echo "# 0.1.8 copy" > "$gate"
  out=$(sim_install "$pkg")
  if printf '%s' "$out" | grep -q 'First install with a record: 1 existing file from an earlier version replaced' && cmp -s "$pkg/hooks/commit-message-gate.sh" "$gate"; then
    sim_pass "the first recorded install replaces an earlier version's file and prints how many it replaced"
  else
    sim_fail "the first recorded install replaces an earlier version's file and prints how many it replaced" "${out:0:300}"
  fi
  if "$JQ" -e '.files["hooks/commit-message-gate.sh"] and .version and (.registrations | length > 0)' "$claude/achilles-install.json" >/dev/null 2>&1; then
    sim_pass "install record lists the installed files (with hashes), the version and the registrations"
  else
    sim_fail "install record lists the installed files (with hashes), the version and the registrations" "no usable record at $claude/achilles-install.json"
  fi

  local settings_before record_before
  settings_before=$(cat "$claude/settings.json"); record_before=$(cat "$claude/achilles-install.json")
  out=$(sim_install "$pkg")
  if [ "$settings_before" = "$(cat "$claude/settings.json")" ] && [ "$record_before" = "$(cat "$claude/achilles-install.json")" ] \
     && printf '%s' "$out" | grep -q ': 0 scripts copied'; then
    sim_pass "second install copies nothing and leaves settings.json and the record byte-identical"
  else
    sim_fail "second install copies nothing and leaves settings.json and the record byte-identical" "${out:0:200}"
  fi

  echo "# upgraded" >> "$pkg/hooks/commit-message-gate.sh"; touch -t 198501010000 "$pkg/hooks/commit-message-gate.sh"
  sim_install "$pkg" >/dev/null
  if cmp -s "$pkg/hooks/commit-message-gate.sh" "$gate"; then
    sim_pass "upgrade from a 1985-mtime tarball refreshes a changed hook"
  else
    sim_fail "upgrade from a 1985-mtime tarball refreshes a changed hook" "installed hook still differs from the packaged one"
  fi

  # A previous package shipped retired-helper.sh and a registered retired-gate.sh;
  # the current one ships neither.
  local retired_gate="$claude/hooks/retired-gate.sh"
  printf '#!/bin/bash\n' > "$retired_gate"
  "$JQ" --arg c "$retired_gate" '.hooks.PreToolUse += [{matcher:"Bash", hooks:[{type:"command", command:$c}]}]' \
    "$claude/settings.json" > "$work/s.json" && mv "$work/s.json" "$claude/settings.json"
  "$JQ" --arg h "$(shasum -a 256 "$retired_gate" | cut -d' ' -f1)" '.files["hooks/retired-gate.sh"] = $h' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  rm "$pkg/hooks/lib/retired-helper.sh"
  sim_install "$pkg" >/dev/null
  if [ ! -e "$claude/hooks/lib/retired-helper.sh" ] && [ ! -e "$retired_gate" ] \
     && ! grep -q retired-gate "$claude/settings.json" && ! grep -q retired "$claude/achilles-install.json"; then
    sim_pass "files the new package dropped are pruned, with their registration and record entry"
  else
    sim_fail "files the new package dropped are pruned, with their registration and record entry" "a dropped file, registration or record entry survived"
  fi

  # A user edit survives both an upgrade and a prune.
  echo "# mine" >> "$gate"
  echo "# upgraded again" >> "$pkg/hooks/commit-message-gate.sh"
  echo "# mine too" >> "$claude/hooks/lib/hook-io.sh"; rm "$pkg/hooks/lib/hook-io.sh"
  out=$(sim_install "$pkg")
  if grep -q '^# mine$' "$gate" && ! grep -q 'upgraded again' "$gate" && grep -q 'mine too' "$claude/hooks/lib/hook-io.sh" \
     && printf '%s' "$out" | grep -q 'commit-message-gate.sh was modified' \
     && printf '%s' "$out" | grep -q 'hook-io.sh is no longer shipped but was modified'; then
    sim_pass "a user-modified file is neither overwritten nor pruned, and the skip is warned"
  else
    sim_fail "a user-modified file is neither overwritten nor pruned, and the skip is warned" "${out:0:300}"
  fi

  # The warning for a kept file prints once, not on every install.
  out=$(sim_install "$pkg")
  if printf '%s' "$out" | grep -q 'was modified\|but was modified'; then
    sim_fail "a kept user-modified file is warned about once" "second run warned again: ${out:0:200}"
  else
    sim_pass "a kept user-modified file is warned about once"
  fi

  # A recorded path that reaches outside .claude through a symlinked directory is never deleted.
  local outside="$work/outside"
  mkdir -p "$outside"; echo victim > "$outside/v2"; ln -s "$outside" "$claude/hooks/escdir"
  "$JQ" --arg h "$(shasum -a 256 "$outside/v2" | cut -d' ' -f1)" '.files["hooks/escdir/v2"] = $h' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  sim_install "$pkg" >/dev/null
  if [ -f "$outside/v2" ]; then
    sim_pass "prune never follows a symlinked directory out of .claude"
  else
    sim_fail "prune never follows a symlinked directory out of .claude" "$outside/v2 was deleted"
  fi
  rm -f "$claude/hooks/escdir"

  # A non-canonical record key for a file the package still ships must not get it deleted.
  "$JQ" --arg h "$(shasum -a 256 "$gate" | cut -d' ' -f1)" '.files["hooks/./commit-message-gate.sh"] = $h' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  sim_install "$pkg" >/dev/null
  if [ -f "$gate" ]; then
    sim_pass "a non-canonical record key never deletes a file the package still ships"
  else
    sim_fail "a non-canonical record key never deletes a file the package still ships" "$gate was deleted"
  fi

  # A record that parses to something other than an object must not stop the install.
  local bad ok=1
  for bad in null '[]' '{"files":null}' '{"files":' 'true'; do
    printf '%s' "$bad" > "$claude/achilles-install.json"
    echo "# upgraded $RANDOM" >> "$pkg/hooks/lib/hook-emit.sh"
    sim_install "$pkg" >/dev/null
    cmp -s "$pkg/hooks/lib/hook-emit.sh" "$claude/hooks/lib/hook-emit.sh" && "$JQ" -e .files "$claude/achilles-install.json" >/dev/null 2>&1 || ok=0
  done
  if [ "$ok" = 1 ]; then
    sim_pass "an unusable install record (null, array, truncated) is treated as absent"
  else
    sim_fail "an unusable install record (null, array, truncated) is treated as absent" "install did not refresh after record '$bad'"
  fi

  # A registration the record says Achilles made, which the manifest no longer asks for, is dropped
  # (its script stays); a user's registration in the same group is not touched.
  local demoted="$claude/hooks/lib/hook-io.sh" mine="/opt/mine/hook.sh"
  "$JQ" --arg c "$demoted" --arg m "$mine" '.hooks.PreToolUse += [{matcher:"Edit", hooks:[{type:"command", command:$c},{type:"command", command:$m}]}]' \
    "$claude/settings.json" > "$work/s.json" && mv "$work/s.json" "$claude/settings.json"
  "$JQ" --arg c "$demoted" '.registrations += [{event:"PreToolUse", matcher:"Edit", command:$c}]' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  sim_install "$pkg" >/dev/null
  if [ -f "$demoted" ] && ! grep -q "$demoted" "$claude/settings.json" && grep -q "$mine" "$claude/settings.json"; then
    sim_pass "a registration no longer in the manifest is dropped; user registrations in the group survive"
  else
    sim_fail "a registration no longer in the manifest is dropped; user registrations in the group survive" "settings: $("$JQ" -c '.hooks.PreToolUse[] | select(.matcher=="Edit")' "$claude/settings.json" 2>&1 | head -c 200)"
  fi

  # Global install: the project root resolves to npm's lib/, which must stay clean.
  local lib="$work/lib" gpkg
  gpkg="$lib/node_modules/@civitas-cerebrum/achilles"
  mkdir -p "$work/ghome"
  sim_make_package "$gpkg"
  HOME="$work/ghome" npm_config_global=true CIVITAS_SKIP_JQ_INSTALL=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    node "$gpkg/scripts/postinstall.js" >/dev/null 2>&1
  if [ -f "$work/ghome/.claude/achilles-install.json" ] && [ -z "$(find "$lib" -name .claude 2>/dev/null)" ]; then
    sim_pass "global install records into ~/.claude and writes no .claude under npm's lib/"
  else
    sim_fail "global install records into ~/.claude and writes no .claude under npm's lib/" "$(find "$lib" -name .claude 2>&1 | head -3)"
  fi
}

# Staged mandate: refreshed while unedited, never overwritten once edited.
run_mandate_simulation() {
  local work pkg proj dest ledger stamp out
  work=$(mktemp -d /tmp/achilles-mandate-sim-XXXXXX)
  _SIM_MANDATE_WORK="$work"
  trap 'rm -rf "$_SIM_WORK" "$_SIM_ERRFILE" "$_SIM_UPGRADE_WORK" "$_SIM_MANDATE_WORK" "$_SIM_METHOD_WORK" "$_SIM_UNINSTALL_WORK"' EXIT
  pkg="$work/pkg"; proj="$work/project"
  sim_make_package "$pkg"
  dest="$proj/.claude/kernel-mandate.json"; ledger="$proj/.claude/kernel-mandate.md"; stamp="$proj/.claude/kernel-mandate.achilles.json"
  local src="$pkg/hooks/data/achilles-qa.kernel-mandate.json"
  sim_stage() {
    CIVITAS_SKIP_HOOK_INSTALL= node -e "require('$INSTALL_SIM_REPO_ROOT/scripts/install/mandate.js').stageProjectMandate('$proj', { packageDir: '$pkg' })" 2>&1
  }

  sim_stage >/dev/null
  if cmp -s "$dest" "$src" && cmp -s "$ledger" "$pkg/hooks/data/achilles-qa.kernel-mandate.md" \
     && [ "$("$JQ" -r .manifestSha256 "$stamp")" = "$(shasum -a 256 "$src" | cut -d' ' -f1)" ]; then
    sim_pass "fresh project: manifest, ledger and sidecar stamp are staged"
  else
    sim_fail "fresh project: manifest, ledger and sidecar stamp are staged" "dest/ledger/stamp mismatch"
  fi

  "$JQ" '.name = "next-release"' "$src" > "$work/m.json" && mv "$work/m.json" "$src"
  out=$(sim_stage)
  if cmp -s "$dest" "$src" && printf '%s' "$out" | grep -q refreshed && [ ! -e "$proj/.claude/kernel-mandate.achilles-new.json" ]; then
    sim_pass "an unedited staged mandate is refreshed on upgrade"
  else
    sim_fail "an unedited staged mandate is refreshed on upgrade" "${out:0:200}"
  fi

  echo '{"kernelMandateVersion":1,"name":"mine","roles":{}}' > "$dest"
  local mine; mine=$(cat "$dest")
  "$JQ" '.name = "release-after"' "$src" > "$work/m.json" && mv "$work/m.json" "$src"
  out=$(sim_stage)
  if [ "$(cat "$dest")" = "$mine" ] && cmp -s "$proj/.claude/kernel-mandate.achilles-new.json" "$src" \
     && [ "$(printf '%s' "$out" | grep -c 'Kept your')" = 1 ]; then
    sim_pass "an edited mandate is left alone, the new one is written beside it, with one notice"
  else
    sim_fail "an edited mandate is left alone, the new one is written beside it, with one notice" "${out:0:200}"
  fi
  out=$(sim_stage)
  if [ -z "$out" ] && [ "$(cat "$dest")" = "$mine" ]; then
    sim_pass "re-running over an edited mandate is silent"
  else
    sim_fail "re-running over an edited mandate is silent" "${out:0:200}"
  fi

  rm -rf "$proj"
  mkdir -p "$proj/.claude"; echo "$mine" > "$dest"
  out=$(sim_stage)
  if [ "$(cat "$dest")" = "$mine" ] && [ -f "$proj/.claude/kernel-mandate.achilles-new.json" ]; then
    sim_pass "a manifest with no sidecar (pre-stamp install or hand-written) is kept, new one written beside it"
  else
    sim_fail "a manifest with no sidecar (pre-stamp install or hand-written) is kept, new one written beside it" "${out:0:200}"
  fi
}

# Skills and agents are copied by content, recorded, and pruned like hooks.
run_methodology_simulation() {
  local work claude out
  work=$(mktemp -d /tmp/achilles-method-sim-XXXXXX)
  _SIM_METHOD_WORK="$work"
  claude="$work/home/.claude"
  local src="$work/skills-src"
  mkdir -p "$src/alpha/references" "$src/beta"
  echo "alpha v1" > "$src/alpha/SKILL.md"; echo "ref v1" > "$src/alpha/references/r.md"; echo "beta v1" > "$src/beta/SKILL.md"
  sim_skills() {
    HOME="$work/home" node -e "require('$INSTALL_SIM_REPO_ROOT/scripts/install/skills.js').installCivitasSkills(['$claude/skills'], '$src')" 2>&1
  }

  sim_skills >/dev/null
  if "$JQ" -e '.files | has("skills/alpha/SKILL.md") and has("skills/alpha/references/r.md") and has("skills/beta/SKILL.md")' "$claude/achilles-install.json" >/dev/null 2>&1; then
    sim_pass "skills are copied and recorded with hashes"
  else
    sim_fail "skills are copied and recorded with hashes" "record: $(head -c 200 "$claude/achilles-install.json" 2>&1)"
  fi

  echo "alpha v2" > "$src/alpha/SKILL.md"; touch -t 198501010000 "$src/alpha/SKILL.md"
  sim_skills >/dev/null
  if [ "$(cat "$claude/skills/alpha/SKILL.md")" = "alpha v2" ]; then
    sim_pass "a changed skill file is refreshed from a 1985-mtime package"
  else
    sim_fail "a changed skill file is refreshed from a 1985-mtime package" "$(cat "$claude/skills/alpha/SKILL.md")"
  fi

  echo "my alpha" > "$claude/skills/alpha/SKILL.md"; echo "alpha v3" > "$src/alpha/SKILL.md"
  echo "my beta" > "$claude/skills/beta/SKILL.md"; rm -r "$src/beta"
  out=$(sim_skills)
  if [ "$(cat "$claude/skills/alpha/SKILL.md")" = "my alpha" ] && [ "$(cat "$claude/skills/beta/SKILL.md")" = "my beta" ] \
     && printf '%s' "$out" | grep -q 'alpha/SKILL.md was modified' && printf '%s' "$out" | grep -q 'beta/SKILL.md is no longer shipped but was modified'; then
    sim_pass "a user-modified skill file is neither overwritten nor pruned"
  else
    sim_fail "a user-modified skill file is neither overwritten nor pruned" "${out:0:300}"
  fi

  echo "beta v1" > "$claude/skills/beta/SKILL.md"
  "$JQ" --arg h "$(shasum -a 256 "$claude/skills/beta/SKILL.md" | cut -d' ' -f1)" '.files["skills/beta/SKILL.md"] = $h | del(.kept)' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  sim_skills >/dev/null
  if [ ! -e "$claude/skills/beta" ]; then
    sim_pass "an unmodified skill the package dropped is pruned, with its empty directory"
  else
    sim_fail "an unmodified skill the package dropped is pruned, with its empty directory" "$(ls "$claude/skills/beta")"
  fi

  # Agents share the claude dir with skills: neither installer drops the other's entries.
  local asrc="$work/agents-src"
  mkdir -p "$asrc"; printf 'role\n<!-- installed-by: @civitas-cerebrum/achilles -->\n' > "$asrc/fd.md"
  HOME="$work/home" node -e "require('$INSTALL_SIM_REPO_ROOT/scripts/install/agents.js').installCivitasAgents(['$claude/agents'], '$asrc')" >/dev/null 2>&1
  sim_skills >/dev/null
  if "$JQ" -e '.files | has("agents/fd.md") and has("skills/alpha/SKILL.md")' "$claude/achilles-install.json" >/dev/null 2>&1; then
    sim_pass "skills and agents keep each other's record entries"
  else
    sim_fail "skills and agents keep each other's record entries" "$(head -c 300 "$claude/achilles-install.json")"
  fi
}

# achilles-uninstall reverses the record and nothing else.
run_uninstall_simulation() {
  local repo_root="$INSTALL_SIM_REPO_ROOT" work proj claude out rc
  work=$(mktemp -d /tmp/achilles-uninstall-sim-XXXXXX)
  _SIM_UNINSTALL_WORK="$work"
  proj="$work/project"; claude="$proj/.claude"
  mkdir -p "$work/skills-src/alpha" "$work/home"
  echo alpha > "$work/skills-src/alpha/SKILL.md"
  sim_full_install() {
    HOME="$work/home" CIVITAS_SKIP_JQ_INSTALL=1 CIVITAS_SKIP_HOOK_INSTALL= node -e "
      const pi = require('$repo_root/scripts/postinstall.js');
      pi.installCivitasHooks('$claude');
      pi.installCivitasSkills(['$claude/skills'], '$work/skills-src');
      pi.stageProjectMandate('$proj');" >/dev/null 2>&1
  }
  sim_uninstall() { HOME="$work/home" node "$repo_root/bin/achilles-uninstall.mjs" "$@" 2>&1; }
  mkdir -p "$claude/hooks/bin"; echo "fake jq" > "$claude/hooks/bin/jq"
  sim_full_install

  # A second install with nothing to change writes nothing and says so.
  local mtime_before mtime_after rerun
  mtime_before=$(node -p "require('fs').statSync('$claude/achilles-install.json').mtimeMs")
  rerun=$(HOME="$work/home" CIVITAS_SKIP_JQ_INSTALL=1 node -e "
    const pi = require('$repo_root/scripts/postinstall.js');
    pi.installCivitasHooks('$claude');
    pi.installCivitasSkills(['$claude/skills'], '$work/skills-src');" 2>&1)
  mtime_after=$(node -p "require('fs').statSync('$claude/achilles-install.json').mtimeMs")
  if [ "$mtime_before" = "$mtime_after" ] && ! printf '%s' "$rerun" | grep -q 'skills\? installed' && printf '%s' "$rerun" | grep -q 'Skills unchanged'; then
    sim_pass "a no-op re-install leaves the record untouched and reports skills unchanged"
  else
    sim_fail "a no-op re-install leaves the record untouched and reports skills unchanged" "mtime $mtime_before -> $mtime_after; ${rerun:0:300}"
  fi

  # Runtime state the kernel wrote, and a user-level record a local install leaves behind.
  mkdir -p "$claude/kernel-mandate.state" "$work/home/.claude"; echo '{}' > "$claude/kernel-mandate.state/decision-log.jsonl"
  echo '{"files":{}}' > "$work/home/.claude/achilles-install.json"
  "$JQ" '.hooks.PreToolUse += [{matcher:"Bash", hooks:[{type:"command", command:"echo mine"}]}]' "$claude/settings.json" > "$work/s.json" && mv "$work/s.json" "$claude/settings.json"
  echo "my edit" >> "$claude/hooks/commit-message-gate.sh"

  # A crafted record: keys that would reach outside .claude, or name a live file non-canonically.
  local outside="$work/outside" vhash ghash
  mkdir -p "$outside"; echo victim > "$outside/v"; ln -s "$outside" "$claude/hooks/escdir"
  vhash=$(shasum -a 256 "$outside/v" | cut -d' ' -f1)
  echo "user script" > "$claude/hooks/user-owned.sh"
  ghash=$(shasum -a 256 "$claude/hooks/user-owned.sh" | cut -d' ' -f1)
  "$JQ" --arg v "$vhash" --arg g "$ghash" --arg abs "$outside/v" \
    '.files["hooks/escdir/v"] = $v | .files["../../outside/v"] = $v | .files[$abs] = $v | .files["hooks/./user-owned.sh"] = $g' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  # Keys outside hooks/, skills/ and agents/ with matching hashes, and a forged registration of the user's.
  echo "my notes" > "$claude/CLAUDE.md"
  "$JQ" --arg s "$(shasum -a 256 "$claude/settings.json" | cut -d' ' -f1)" --arg c "$(shasum -a 256 "$claude/CLAUDE.md" | cut -d' ' -f1)" \
    '.files["settings.json"] = $s | .files["CLAUDE.md"] = $c | .registrations += [{event:"PreToolUse", matcher:"Bash", command:"echo mine"}]' \
    "$claude/achilles-install.json" > "$work/r.json" && mv "$work/r.json" "$claude/achilles-install.json"
  local before; before=$(find "$claude" -type f | sort | shasum)

  out=$(sim_uninstall --project "$proj" --dry-run); rc=$?
  if [ "$rc" = 0 ] && [ "$before" = "$(find "$claude" -type f | sort | shasum)" ] && printf '%s' "$out" | grep -q '^would remove'; then
    sim_pass "uninstall --dry-run reports and changes nothing"
  else
    sim_fail "uninstall --dry-run reports and changes nothing" "rc=$rc ${out:0:200}"
  fi

  out=$(sim_uninstall --project "$proj"); rc=$?
  local achilles_left
  achilles_left=$("$JQ" '[.. | .command? // empty | select(test("achilles|kernel-mandate|/factory/|/hooks/"))] | length' "$claude/settings.json" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$achilles_left" = 0 ] && grep -q 'echo mine' "$claude/settings.json" && printf '%s' "$out" | grep -Eq 'remove [0-9]+ registrations? from'; then
    sim_pass "uninstall removes Achilles registrations; a user's registration in the same settings.json survives"
  else
    sim_fail "uninstall removes Achilles registrations; a user's registration in the same settings.json survives" "rc=$rc left=$achilles_left ${out:0:200}"
  fi
  if [ ! -e "$claude/skills/alpha/SKILL.md" ] && [ ! -e "$claude/hooks/lib/hook-io.sh" ] && [ ! -e "$claude/achilles-install.json" ]; then
    sim_pass "uninstall deletes recorded hooks and skills and, last, the record"
  else
    sim_fail "uninstall deletes recorded hooks and skills and, last, the record" "$(find "$claude" -type f | head -5)"
  fi
  if grep -q 'my edit' "$claude/hooks/commit-message-gate.sh" && printf '%s' "$out" | grep -q 'kept .*commit-message-gate.sh'; then
    sim_pass "uninstall keeps a modified recorded file and says so"
  else
    sim_fail "uninstall keeps a modified recorded file and says so" "${out:0:300}"
  fi
  if [ ! -e "$claude/kernel-mandate.state" ] && [ "$("$JQ" '[.hooks[] | select(length == 0)] | length' "$claude/settings.json")" = 0 ]; then
    sim_pass "uninstall removes the kernel's runtime state and leaves no empty hook arrays"
  else
    sim_fail "uninstall removes the kernel's runtime state and leaves no empty hook arrays" "$(ls "$claude"; cat "$claude/settings.json")"
  fi
  if printf '%s' "$out" | grep -q 'remain; remove them with: achilles-uninstall --global'; then
    sim_pass "uninstall --project says user-level copies remain and how to remove them"
  else
    sim_fail "uninstall --project says user-level copies remain and how to remove them" "${out:0:300}"
  fi
  if [ ! -e "$claude/kernel-mandate.json" ] && [ ! -e "$claude/kernel-mandate.md" ] && [ ! -e "$claude/kernel-mandate.achilles.json" ]; then
    sim_pass "uninstall removes an unmodified staged mandate with its stamp"
  else
    sim_fail "uninstall removes an unmodified staged mandate with its stamp" "$(ls "$claude")"
  fi
  if [ -f "$claude/settings.json" ] && [ -f "$claude/CLAUDE.md" ]; then
    sim_pass "a record listing settings.json and CLAUDE.md with matching hashes deletes neither"
  else
    sim_fail "a record listing settings.json and CLAUDE.md with matching hashes deletes neither" "$(ls "$claude")"
  fi
  if [ ! -e "$claude/hooks/bin/jq" ] && [ ! -d "$claude/hooks/bin" ]; then
    sim_pass "the bundled jq is recorded and removed with its empty directory"
  else
    sim_fail "the bundled jq is recorded and removed with its empty directory" "$(ls -R "$claude/hooks" 2>&1 | head -5)"
  fi
  if [ -f "$outside/v" ] && [ -L "$claude/hooks/escdir" ] && [ -f "$claude/hooks/user-owned.sh" ]; then
    sim_pass "crafted record keys (symlinked dir, .., absolute, non-canonical) delete nothing outside or off the canonical path"
  else
    sim_fail "crafted record keys (symlinked dir, .., absolute, non-canonical) delete nothing outside or off the canonical path" "outside=$(ls "$outside") user_file=$(ls "$claude/hooks/user-owned.sh" 2>&1)"
  fi
  sim_uninstall --project "$proj" >/dev/null; rc=$?
  if [ "$rc" = 1 ]; then sim_pass "uninstall exits 1 when nothing is recorded"; else sim_fail "uninstall exits 1 when nothing is recorded" "rc=$rc"; fi
  sim_uninstall --bogus >/dev/null; rc=$?
  if [ "$rc" = 2 ]; then sim_pass "uninstall exits 2 on a usage error"; else sim_fail "uninstall exits 2 on a usage error" "rc=$rc"; fi

  # An unusable record is reported, not acted on, and kept.
  printf 'null' > "$claude/achilles-install.json"
  out=$(sim_uninstall --project "$proj"); rc=$?
  if [ "$rc" = 1 ] && [ -f "$claude/achilles-install.json" ] && printf '%s' "$out" | grep -q unusable; then
    sim_pass "an unusable record exits 1 and is left in place"
  else
    sim_fail "an unusable record exits 1 and is left in place" "rc=$rc ${out:0:200}"
  fi

  # An edited mandate survives uninstall.
  rm -rf "$proj"; sim_full_install; echo '{"mine":1}' > "$claude/kernel-mandate.json"
  out=$(sim_uninstall --project "$proj")
  if [ "$(cat "$claude/kernel-mandate.json")" = '{"mine":1}' ] && [ ! -e "$claude/kernel-mandate.md" ]; then
    sim_pass "uninstall keeps an edited mandate"
  else
    sim_fail "uninstall keeps an edited mandate" "${out:0:300}"
  fi

  # --global reverses ~/.claude.
  HOME="$work/home" CIVITAS_SKIP_JQ_INSTALL=1 node -e "require('$repo_root/scripts/postinstall.js').installCivitasHooks('$work/home/.claude')" >/dev/null 2>&1
  out=$(sim_uninstall --global); rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$work/home/.claude/achilles-install.json" ] && [ ! -e "$work/home/.claude/hooks/commit-message-gate.sh" ]; then
    sim_pass "uninstall --global reverses the user-level record"
  else
    sim_fail "uninstall --global reverses the user-level record" "rc=$rc ${out:0:300}"
  fi
}

run_install_simulation
run_upgrade_simulation
run_mandate_simulation
run_methodology_simulation
run_uninstall_simulation

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
