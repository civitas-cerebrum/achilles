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

if ! command -v node >/dev/null 2>&1; then
  echo "  ${CLR_DIM}(node not on PATH — skipping postinstall scope tests)${CLR_RST}"
  return 0 2>/dev/null || exit 0
fi

REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
SCOPE_TEST=$(mktemp /tmp/scope-test-XXXXXX.mjs)
SCOPE_HOME=$(mktemp -d /tmp/scope-home-XXXXXX)

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

rm -f "$SCOPE_TEST"
rm -rf "$SCOPE_HOME"
