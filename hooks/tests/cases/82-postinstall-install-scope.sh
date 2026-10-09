#!/bin/bash
# Tests for scripts/postinstall.js install scoping:
#   - `npm install -g`  → harness system-wide (~/.claude), skills user-level
#     only — npm's lib/ dir must NEVER receive a .claude/ tree.
#   - `npm install`     → harness in the consuming project only
#     (<project>/.claude/hooks + settings.json), skills project + user.
#   - installCivitasHooks(claudeDir) honours an explicit target, and the
#     no-arg call keeps installing user-level (sync-hooks.js compat).
#
# Node-level tests: each scenario runs in a fresh node process because the
# scope decision is computed at module load from npm_config_global.
# CIVITAS_SKIP_JQ_INSTALL=1 keeps everything offline.

require_tool node || return 0

REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
SCOPE_TEST=$(mktemp /tmp/scope-test-XXXXXX.mjs)
tmp_into SCOPE_HOME /tmp/scope-home-XXXXXX

echo
echo "── postinstall: install scope follows the -g flag ──"

cat > "$SCOPE_TEST" <<EOF
import { strict as assert } from 'assert';
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
const home = '$SCOPE_HOME';
process.env.HOME = home;
process.env.CIVITAS_SKIP_JQ_INSTALL = '1';
const require = createRequire(import.meta.url);
const pi = require(path.join('$REPO_ROOT', 'scripts', 'postinstall.js'));
const mode = process.argv[2];

if (mode === 'global-flag') {
  // npm_config_global=true (set by the wrapper) → global scope: harness under
  // ~/.claude, skills user-level ONLY — no project-level destination that
  // would land a .claude/ tree in npm's lib/ dir.
  assert.equal(pi.isGlobalInstall(), true, '-g detected');
  assert.equal(pi.harnessClaudeDir, path.join(home, '.claude'), 'harness → ~/.claude');
  assert.deepEqual(pi.skillsDestinations, [path.join(home, '.claude', 'skills')],
    'skills → user-level only');
  console.log('GLOBAL_SCOPE_OK');
} else if (mode === 'local-flag') {
  // npm_config_global unset/false in-repo → local scope: harness pinned to
  // the project, skills to project + user (methodology stays system-wide).
  assert.equal(pi.isGlobalInstall(), false, 'no -g → local');
  assert.ok(!pi.harnessClaudeDir.startsWith(path.join(home, '.claude')),
    'harness dir is NOT user-level on a local install');
  assert.equal(pi.skillsDestinations.length, 2, 'skills → project + user');
  assert.ok(pi.skillsDestinations.includes(path.join(home, '.claude', 'skills')),
    'user-level skills destination kept');
  console.log('LOCAL_SCOPE_OK');
} else if (mode === 'target-dir') {
  // installCivitasHooks(claudeDir) honours the explicit target: hooks +
  // settings.json land under it — this is the project-local install path.
  const projClaude = path.join(home, 'project', '.claude');
  pi.installCivitasHooks(projClaude);
  assert.ok(fs.existsSync(path.join(projClaude, 'hooks', 'commit-message-gate.sh')),
    'hook script copied under the target .claude/hooks');
  const settings = JSON.parse(fs.readFileSync(path.join(projClaude, 'settings.json'), 'utf8'));
  const cmds = Object.values(settings.hooks).flat().flatMap(g => (g.hooks || []).map(h => h.command));
  assert.ok(cmds.length > 0 && cmds.every(c => c.startsWith(path.join(projClaude, 'hooks') + path.sep)),
    'every registration points into the target hooks dir');
  assert.ok(!fs.existsSync(path.join(home, '.claude', 'settings.json')),
    'user-level settings.json untouched by a project-scoped install');
  // No-arg call keeps the historical user-level default (sync-hooks.js compat).
  pi.installCivitasHooks();
  assert.ok(fs.existsSync(path.join(home, '.claude', 'hooks', 'commit-message-gate.sh')),
    'no-arg call still installs user-level');
  console.log('TARGET_DIR_OK');
} else if (mode === 'agents') {
  // One definition per subagent role lands; a rerun changes nothing; a
  // user-authored same-name file survives; a file an earlier package shipped
  // and this one dropped is pruned.
  const dest = path.join(home, 'agents-dest', 'agents');
  const oldSrc = path.join(home, 'old-agents-src');
  const roles = Object.keys(JSON.parse(fs.readFileSync(path.join('$REPO_ROOT', 'hooks/data/achilles-qa.kernel-mandate.json'), 'utf8')).roles).filter(r => r !== 'orchestrator');
  assert.ok(pi.agentsDestinations.includes(path.join(home, '.claude', 'agents')), 'user-level agents destination');
  fs.mkdirSync(dest, { recursive: true });
  fs.writeFileSync(path.join(dest, 'fd.md'), 'my own fd agent\n');
  fs.mkdirSync(oldSrc, { recursive: true });
  fs.writeFileSync(path.join(oldSrc, 'retired.md'), 'x\n<!-- installed-by: @civitas-cerebrum/achilles -->\n');
  pi.installCivitasAgents([dest], oldSrc);
  assert.ok(fs.existsSync(path.join(dest, 'retired.md')), 'earlier package installed retired.md');
  fs.writeFileSync(path.join(dest, 'mine.md'), 'user file\n');
  const first = pi.installCivitasAgents([dest]);
  for (const r of roles.filter(r => r !== 'fd')) assert.ok(fs.existsSync(path.join(dest, r + '.md')), r + ' installed');
  assert.equal(fs.readFileSync(path.join(dest, 'fd.md'), 'utf8'), 'my own fd agent\n', 'user-authored file untouched');
  assert.deepEqual(first.skipped, [path.join(dest, 'fd.md')], 'skip reported');
  assert.ok(!fs.existsSync(path.join(dest, 'retired.md')), 'retired marked file pruned');
  assert.ok(fs.existsSync(path.join(dest, 'mine.md')), 'unmarked file never pruned');
  const mtimes = roles.map(r => fs.statSync(path.join(dest, r + '.md')).mtimeMs);
  await new Promise(r => setTimeout(r, 20));
  const second = pi.installCivitasAgents([dest]);
  assert.deepEqual(roles.map(r => fs.statSync(path.join(dest, r + '.md')).mtimeMs), mtimes, 'second run rewrites nothing');
  assert.deepEqual(second.skipped, [path.join(dest, 'fd.md')], 'skip still reported');
  console.log('AGENTS_OK');
}
EOF

TESTS_RUN=$((TESTS_RUN + 1))
OUT=$(HOME="$SCOPE_HOME" npm_config_global=true node "$SCOPE_TEST" global-flag 2>&1 || true)
if echo "$OUT" | grep -q GLOBAL_SCOPE_OK; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} -g install → harness system-wide, skills user-level only"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("postinstall-scope global-flag: ${OUT:0:300}")
  echo "${CLR_FAIL}  ✗${CLR_RST} -g install → harness system-wide, skills user-level only ${CLR_DIM}(${OUT:0:160})${CLR_RST}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
OUT=$(HOME="$SCOPE_HOME" node "$SCOPE_TEST" local-flag 2>&1 || true)
if echo "$OUT" | grep -q LOCAL_SCOPE_OK; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} local install → harness project-scoped, skills project + user"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("postinstall-scope local-flag: ${OUT:0:300}")
  echo "${CLR_FAIL}  ✗${CLR_RST} local install → harness project-scoped, skills project + user ${CLR_DIM}(${OUT:0:160})${CLR_RST}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
OUT=$(HOME="$SCOPE_HOME" node "$SCOPE_TEST" target-dir 2>&1 || true)
if echo "$OUT" | grep -q TARGET_DIR_OK; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} installCivitasHooks(dir) targets that dir; no-arg default stays user-level"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("postinstall-scope target-dir: ${OUT:0:300}")
  echo "${CLR_FAIL}  ✗${CLR_RST} installCivitasHooks(dir) targets that dir; no-arg default stays user-level ${CLR_DIM}(${OUT:0:160})${CLR_RST}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
OUT=$(HOME="$SCOPE_HOME" node "$SCOPE_TEST" agents 2>&1 || true)
if echo "$OUT" | grep -q AGENTS_OK; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} agents: one per role installed, rerun is a no-op, user file kept, retired file pruned"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("postinstall-scope agents: ${OUT:0:300}")
  echo "${CLR_FAIL}  ✗${CLR_RST} agents install ${CLR_DIM}(${OUT:0:160})${CLR_RST}"
fi

rm -f "$SCOPE_TEST"
