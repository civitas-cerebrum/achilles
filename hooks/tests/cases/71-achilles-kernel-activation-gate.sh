#!/bin/bash
# Tests for achilles-kernel-activation-gate.sh — the REGISTERED entry point
# to the kernel mandate kernel — together with the postinstall wiring that
# puts it there and the QA mandate it consults.
#
# Contract under test:
#   - postinstall registers the WRAPPER on PreToolUse:.* and no longer
#     registers the raw kernel; the kernel is copied beside the wrapper as
#     a companion (the wrapper execs it) and a stale direct registration
#     is pruned.
#   - hooks/data/achilles-qa.kernel-mandate.json is a valid manifest,
#     derived from hooks/data/achilles-qa.workflow.json, and LOADS in the
#     vendored kernel with the intended boundaries (no role reads src/**
#     or .env; approvers have no shell; the main session is `orchestrator`).
#   - the wrapper is dormant without an achilles session marker and relays
#     the kernel's verdict with one; KERNEL_MANDATE=0 still bypasses; a
#     missing kernel script is a silent allow.
#   - postinstall stages the manifest into <project>/.claude/ only when
#     none exists there, never overwrites, and writes nowhere else.

H="$HOOK_DIR/achilles-kernel-activation-gate.sh"
KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
POSTINSTALL="$REPO_ROOT/scripts/postinstall.js"
MANDATE="$HOOK_DIR/data/achilles-qa.kernel-mandate.json"
WORKFLOW="$HOOK_DIR/data/achilles-qa.workflow.json"

# ---------------------------------------------------------------------------
section "kernel wiring: postinstall registers the wrapper, not the raw kernel"
# ---------------------------------------------------------------------------
# HOOK_MANIFEST body only — comments and the companion / superseded lists
# below it must not count as registrations.
MANIFEST_BODY=$(awk '/const HOOK_MANIFEST = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL" | grep -vE '^\s*//')
assert_eq "$(printf '%s' "$MANIFEST_BODY" | grep -cE "file: 'achilles-kernel-activation-gate\.sh',\s+event: 'PreToolUse',\s+matcher: '\.\*'")" "1" \
  "wrapper registered once on PreToolUse with matcher .*"
assert_eq "$(printf '%s' "$MANIFEST_BODY" | grep -c "file: 'kernel-mandate-role-gate\.sh'")" "0" \
  "raw kernel is NOT registered in HOOK_MANIFEST"
COMPANIONS=$(awk '/const HOOK_COMPANIONS = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL")
assert_eq "$(printf '%s' "$COMPANIONS" | grep -c "'kernel-mandate-role-gate\.sh'")" "1" \
  "raw kernel is copied as a companion (wrapper execs it)"
SUPERSEDED=$(awk '/const SUPERSEDED_REGISTRATIONS = \[/{p=1} p{print} p&&/^\];/{exit}' "$POSTINSTALL")
assert_eq "$(printf '%s' "$SUPERSEDED" | grep -c "'kernel-mandate-role-gate\.sh'")" "1" \
  "a stale direct kernel registration is listed for pruning"

# ---------------------------------------------------------------------------
section "kernel wiring: the shipped QA mandate validates and matches its table"
# ---------------------------------------------------------------------------
assert_eq "$([ -f "$WORKFLOW" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.workflow.json ships"
assert_eq "$([ -f "$MANDATE" ] && echo present || echo missing)" "present" "hooks/data/achilles-qa.kernel-mandate.json ships"

if command -v node >/dev/null 2>&1 && node -e "require('ajv/dist/2020.js'); require('ajv-formats');" >/dev/null 2>&1; then
  SCHEMA_VERDICT=$(node -e "
    const Ajv = require('ajv/dist/2020.js'); const addFormats = require('ajv-formats');
    const fs = require('fs');
    const ajv = new Ajv({ strict: false, allErrors: true }); addFormats(ajv);
    const schema = JSON.parse(fs.readFileSync('$REPO_ROOT/schemas/kernel-mandate.schema.json', 'utf8'));
    const doc = JSON.parse(fs.readFileSync('$MANDATE', 'utf8'));
    const ok = ajv.validate(schema, doc);
    console.log(ok ? 'valid' : JSON.stringify(ajv.errors).slice(0, 300));
  " 2>&1)
  assert_eq "$SCHEMA_VERDICT" "valid" "staged manifest validates against the vendored kernel-mandate schema"
else
  echo "  ${CLR_DIM}(ajv not available — skipping schema validation of the QA mandate)${CLR_RST}"
fi

# Table ↔ manifest consistency and the two hard boundaries the design
# states: every role from the table is present (and only those), each
# binds its own agentType, the main session is the orchestrator, and no
# role's read scope names application source or the environment file.
TABLE_CHECK=$("$JQ" -rn --slurpfile wf "$WORKFLOW" --slurpfile m "$MANDATE" '
  ($wf[0]) as $w | ($m[0]) as $k |
  ($w.roles | keys | sort) as $wr | ($k.roles | keys | sort) as $kr |
  [
    (if $wr == $kr then "roles-match" else "roles-differ" end),
    (if $k.settings.mainSessionRole == "orchestrator" then "main=orchestrator" else "main=\($k.settings.mainSessionRole)" end),
    (if ([$k.roles | to_entries[] | select(.value.agentTypes != [.key])] | length) == 0 then "agentTypes=self" else "agentTypes-drift" end),
    (if ([$k.roles[] | (.read.allow // [])[] | select(. == "src/**" or . == ".env" or startswith("src/") or startswith(".env"))] | length) == 0 then "no-src-no-env" else "reads-src-or-env" end)
  ] | join(" ")')
assert_eq "$TABLE_CHECK" "roles-match main=orchestrator agentTypes=self no-src-no-env" \
  "manifest roles == table roles, main session is orchestrator, agentTypes bind by name, nothing reads src/** or .env"

# ---------------------------------------------------------------------------
section "kernel wiring: the QA mandate loads in the vendored kernel"
# ---------------------------------------------------------------------------
KW_TMP=$(mktemp -d)
KP="$KW_TMP/proj"
mkdir -p "$KP/.claude" "$KP/tests/e2e/docs" "$KP/src"
cp "$MANDATE" "$KP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_MANIFEST="$KP/.claude/kernel-mandate.json"
export KERNEL_MANDATE_STATE_DIR="$KW_TMP/state"

# Main session (no agent_id) binds as orchestrator.
assert_deny "$KERNEL" "$(payload tool_name=Read file_path="$KP/src/app.ts" cwd="$KP")" \
  "orchestrator Read src/app.ts → DENY" "outside the role's read scope"
assert_deny "$KERNEL" "$(payload tool_name=Read file_path="$KP/.env" cwd="$KP")" \
  "orchestrator Read .env → DENY" "outside the role's read scope"
assert_allow "$KERNEL" "$(payload tool_name=Read file_path="$KP/package.json" cwd="$KP")" \
  "orchestrator Read package.json → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Write file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}' cwd="$KP")" \
  "orchestrator Write the ledger → ALLOW (SoD lives in the ledger write gate)"
assert_allow "$KERNEL" "$(payload tool_name=Write file_path="$KP/.gitignore" content='.achilles/' cwd="$KP")" \
  "orchestrator Write .gitignore → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command='npx playwright test --list' cwd="$KP")" \
  "orchestrator Bash npx playwright test --list → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Bash command="git commit -m 'chore: scaffold e2e suite'" cwd="$KP")" \
  "orchestrator Bash git commit → ALLOW"
assert_deny "$KERNEL" "$(payload tool_name=Bash command='npm install left-pad' cwd="$KP")" \
  "orchestrator Bash npm install → DENY" "may not run this command"
assert_allow "$KERNEL" "$(payload tool_name=Skill skill=onboarding cwd="$KP")" \
  "orchestrator Skill onboarding → ALLOW"
assert_allow "$KERNEL" "$(payload tool_name=Agent description='workflow-reviewer-phase1: review phase 1' prompt='<<kernel-mandate-role: workflow-reviewer>>
Verify the ledger.' cwd="$KP")" \
  "orchestrator dispatches a tagged workflow-reviewer → ALLOW"

# Subagents bind by the host's agent_type. The kernel caches a binding per
# agent_id, so each role gets its own id — sharing one would re-use the
# first role for every later probe.
sub() { payload "$@" cwd="$KP" | "$JQ" -c '. + {agent_id: ("sub-" + .agent_type)}'; }
assert_deny "$KERNEL" "$(sub tool_name=Bash agent_type=workflow-reviewer command='ls')" \
  "workflow-reviewer Bash → DENY (approvers have no shell)" "may not use the 'Bash' tool"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=workflow-reviewer file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "workflow-reviewer Write the ledger → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=workflow-reviewer file_path="$KP/tests/e2e/login.spec.ts" content='x')" \
  "workflow-reviewer Write a spec → DENY" "outside the role's write scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=perf-reviewer file_path="$KP/tests/e2e/docs/onboarding-status.json" content='{}')" \
  "perf-reviewer Write the e2e ledger → DENY" "outside the role's write scope"
assert_allow "$KERNEL" "$(sub tool_name=Write agent_type=test-composer file_path="$KP/tests/e2e/login.spec.ts" content='import { test } from "./fixtures/auth"; test("x", async () => {});')" \
  "test-composer Write a spec (relative import) → ALLOW"
assert_deny "$KERNEL" "$(sub tool_name=Read agent_type=test-composer file_path="$KP/src/app.ts")" \
  "test-composer Read src/app.ts → DENY" "outside the role's read scope"
assert_deny "$KERNEL" "$(sub tool_name=Write agent_type=selector-diff-validator file_path="$KP/tests/e2e/x.ts" content='x')" \
  "selector-diff-validator Write → DENY (writes nothing)" "may not use the 'Write' tool"

# ---------------------------------------------------------------------------
section "wrapper: dormant without a session marker, consults the kernel with one"
# ---------------------------------------------------------------------------
export ACHILLES_SESSION_STATE_DIR="$KW_TMP/sessions"
mkdir -p "$ACHILLES_SESSION_STATE_DIR"
DEV_TRANSCRIPT="$KW_TMP/dev-transcript.jsonl"
cat > "$DEV_TRANSCRIPT" <<'EOF'
{"type":"user","message":{"content":[{"type":"text","text":"tidy the README"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
EOF
# The one call the kernel would refuse for the orchestrator — used as the
# probe throughout so the only variable is whether the kernel was asked.
probe() { payload session_id="$1" transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KP/src/app.ts" cwd="$KP"; }

assert_allow "$H" "$(probe km-dev-1)" "dev session (no marker, no signal): wrapper → silent ALLOW (dormant)"
assert_deny "$KERNEL" "$(probe km-dev-1)" "…while the raw kernel would DENY the same call (manifest is live on disk)" "outside the role's read scope"

: > "$ACHILLES_SESSION_STATE_DIR/km-act-1.active"
assert_deny "$H" "$(probe km-act-1)" "marker present: wrapper relays the kernel's DENY" "outside the role's read scope"
assert_allow "$H" "$(payload session_id=km-act-1 transcript_path="$DEV_TRANSCRIPT" tool_name=Read file_path="$KP/package.json" cwd="$KP")" \
  "marker present: in-scope Read relays the kernel's ALLOW"
export ACHILLES_PROTOCOL=0
assert_deny "$H" "$(probe km-act-1)" "ACHILLES_PROTOCOL=0 cannot deactivate a live marker → still DENY (one-way lifecycle)" "outside the role's read scope"
assert_allow "$H" "$(probe km-dev-2)" "ACHILLES_PROTOCOL=0 suppresses activation for a fresh session → ALLOW"
unset ACHILLES_PROTOCOL
export KERNEL_MANDATE=0
assert_allow "$H" "$(probe km-act-1)" "KERNEL_MANDATE=0 (operator shell) bypasses through the wrapper → ALLOW"
unset KERNEL_MANDATE

# Activation on the very first protocol-shaped call: the wrapper sees the
# Skill invocation, marks the session, and consults the kernel for it.
assert_allow "$H" "$(payload session_id=km-act-2 transcript_path="$DEV_TRANSCRIPT" tool_name=Skill skill=onboarding cwd="$KP")" \
  "first protocol-shaped call (Skill onboarding) → kernel consulted → ALLOW"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/km-act-2.active" ] && echo marked || echo unmarked)" "marked" \
  "…and the session is now marked active"
assert_deny "$H" "$(probe km-act-2)" "…so the next out-of-scope call is DENIED" "outside the role's read scope"

# Missing session identity fails closed (guards on) — the kernel is asked.
assert_deny "$H" "$(payload tool_name=Read file_path="$KP/src/app.ts" cwd="$KP")" \
  "no session_id: fail-closed → kernel consulted → DENY" "outside the role's read scope"

# Kernel script absent beside the wrapper → nothing to consult → silent allow.
NOK="$KW_TMP/hooks-without-kernel"
mkdir -p "$NOK/lib"
cp "$H" "$NOK/"
cp "$HOOK_DIR"/lib/achilles-activation.sh "$NOK/lib/"
assert_allow "$NOK/achilles-kernel-activation-gate.sh" "$(probe km-act-1)" \
  "marker present but kernel script missing → silent ALLOW (achilles' own gates still apply)"

unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR ACHILLES_SESSION_STATE_DIR

# ---------------------------------------------------------------------------
section "postinstall: stages the QA mandate into the project, never overwrites, prunes the direct kernel registration"
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  WIRE_TEST=$(mktemp "$KW_TMP/wiring-XXXXXX.mjs")
  WIRE_HOME="$KW_TMP/home"
  WIRE_PROJ="$KW_TMP/consumer"
  mkdir -p "$WIRE_HOME/.claude/hooks" "$WIRE_PROJ"
  cat > "$WIRE_TEST" <<EOF
import { strict as assert } from 'assert';
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
const home = '$WIRE_HOME';
const proj = '$WIRE_PROJ';
const userHooks = path.join(home, '.claude', 'hooks');
const settingsPath = path.join(home, '.claude', 'settings.json');
// An upgraded install: the raw kernel is registered directly AND present on disk,
// so the dangling-file prune alone would keep it.
// The stale kernel predates the package (copyHookFile copies on mtime), as
// on any real upgrade — backdate the stub or the test would be testing the
// mtime rule instead of the companion copy.
const staleKernel = path.join(userHooks, 'kernel-mandate-role-gate.sh');
fs.writeFileSync(staleKernel, '#!/bin/bash\nexit 0\n');
const past = new Date(Date.now() - 7 * 24 * 3600 * 1000);
fs.utimesSync(staleKernel, past, past);
fs.writeFileSync(settingsPath, JSON.stringify({ hooks: { PreToolUse: [
  { matcher: '.*', hooks: [ { type: 'command', command: path.join(userHooks, 'kernel-mandate-role-gate.sh'), timeout: 10 } ] },
] } }, null, 2));
process.env.HOME = home;
process.env.CIVITAS_SKIP_JQ_INSTALL = '1';
delete process.env.CIVITAS_SKIP_HOOK_INSTALL;
const require = createRequire(import.meta.url);
const pi = require(path.join('$REPO_ROOT', 'scripts', 'postinstall.js'));

// --- hooks: wrapper registered, direct kernel registration pruned, kernel copied as companion
pi.installCivitasHooks();
const after = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const star = after.hooks.PreToolUse.filter(g => g.matcher === '.*');
const starCmds = star.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(starCmds.some(c => c.endsWith('achilles-kernel-activation-gate.sh')), 'wrapper registered on PreToolUse:.*');
const allCmds = after.hooks.PreToolUse.flatMap(g => (g.hooks || []).map(h => h.command));
assert.ok(!allCmds.some(c => c.endsWith('kernel-mandate-role-gate.sh')), 'direct kernel registration pruned');
const kernelOnDisk = path.join(userHooks, 'kernel-mandate-role-gate.sh');
assert.ok(fs.existsSync(kernelOnDisk), 'kernel still on disk (companion)');
assert.ok(fs.statSync(kernelOnDisk).size > 1000, 'companion copy is the real kernel, not the stub');
assert.ok(fs.existsSync(path.join(userHooks, 'lib', 'kernel-mandate.sh')), 'kernel lib copied');
assert.ok(fs.existsSync(path.join(userHooks, 'data', 'achilles-qa.kernel-mandate.json')), 'hooks/data manifest copied');

// --- staging: lands only when absent
const dest = path.join(proj, '.claude', 'kernel-mandate.json');
assert.ok(!fs.existsSync(dest), 'precondition: no manifest in the project');
pi.stageProjectMandate(proj);
assert.ok(fs.existsSync(dest), 'manifest staged into <project>/.claude/');
const shipped = fs.readFileSync(path.join('$REPO_ROOT', 'hooks', 'data', 'achilles-qa.kernel-mandate.json'), 'utf8');
assert.equal(fs.readFileSync(dest, 'utf8'), shipped, 'staged bytes == shipped bytes');
// nothing outside the project
assert.ok(!fs.existsSync(path.join(home, '.claude', 'kernel-mandate.json')), 'nothing staged under HOME');

// --- never overwrites
const custom = '{"kernelMandateVersion":1,"name":"custom","roles":{}}\n';
fs.writeFileSync(dest, custom);
pi.stageProjectMandate(proj);
assert.equal(fs.readFileSync(dest, 'utf8'), custom, 'existing manifest left byte-for-byte alone');

// --- honours the hook-install opt-out (no hooks → no kernel → nothing to bind)
const proj2 = path.join('$KW_TMP', 'consumer-skip');
fs.mkdirSync(proj2, { recursive: true });
process.env.CIVITAS_SKIP_HOOK_INSTALL = '1';
pi.stageProjectMandate(proj2);
assert.ok(!fs.existsSync(path.join(proj2, '.claude', 'kernel-mandate.json')), 'not staged under CIVITAS_SKIP_HOOK_INSTALL=1');
console.log('WIRING_OK');
EOF
  TESTS_RUN=$((TESTS_RUN + 1))
  WIRE_OUT=$(HOME="$WIRE_HOME" node "$WIRE_TEST" 2>&1 || true)
  if echo "$WIRE_OUT" | grep -q 'WIRING_OK'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} postinstall wires the wrapper, prunes the direct kernel registration, stages the mandate once and never overwrites"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("postinstall kernel wiring: ${WIRE_OUT:0:400}")
    echo "${CLR_FAIL}  ✗${CLR_RST} postinstall kernel wiring ${CLR_DIM}(${WIRE_OUT:0:160})${CLR_RST}"
  fi
else
  echo "  ${CLR_DIM}(node not on PATH — skipping postinstall wiring test)${CLR_RST}"
fi

rm -rf "$KW_TMP"
