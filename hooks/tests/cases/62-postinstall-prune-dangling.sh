#!/bin/bash
# Tests for scripts/postinstall.js pruneDanglingRegistrations (change #14):
# legacy registrations are removed from settings.json on install while
# third-party user hooks are preserved and emptied matcher groups dropped.
#
# Node-level test: drives installCivitasHooks() against a fake HOME with a
# seeded settings.json. CIVITAS_SKIP_JQ_INSTALL=1 keeps it offline; the
# function copies bundled hooks (local file copies, no network).

if ! command -v node >/dev/null 2>&1; then
  echo "  ${CLR_DIM}(node not on PATH — skipping postinstall prune test)${CLR_RST}"
  return 0 2>/dev/null || exit 0
fi

REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
PRUNE_TEST=$(mktemp /tmp/prune-test-XXXXXX.mjs)
PRUNE_HOME=$(mktemp -d /tmp/prune-home-XXXXXX)
cat > "$PRUNE_TEST" <<EOF
import { strict as assert } from 'assert';
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
const home = '$PRUNE_HOME';
const userHooks = path.join(home, '.claude', 'hooks');
fs.mkdirSync(userHooks, { recursive: true });
const settingsPath = path.join(home, '.claude', 'settings.json');
fs.writeFileSync(settingsPath, JSON.stringify({ hooks: { PreToolUse: [
  { matcher: 'Bash', hooks: [
    { type: 'command', command: path.join(userHooks, 'commit-attribution-gate.sh') },
    { type: 'command', command: path.join(userHooks, 'commit-message-gate.sh') },
    { type: 'command', command: path.join(userHooks, 'some-removed-future-hook.sh') },
    { type: 'command', command: '/opt/thirdparty/my-hook.sh' },
  ]},
  { matcher: 'Agent', hooks: [
    { type: 'command', command: path.join(userHooks, 'bash-command-allowlist.sh') },
  ]},
] } }, null, 2));
process.env.HOME = home;
process.env.CIVITAS_SKIP_JQ_INSTALL = '1';
const require = createRequire(import.meta.url);
const pi = require(path.join('$REPO_ROOT', 'scripts', 'postinstall.js'));
pi.installCivitasHooks();
const after = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const cmds = after.hooks.PreToolUse.flatMap(g => (g.hooks||[]).map(h => h.command));
assert.ok(!cmds.some(c => c.endsWith('commit-attribution-gate.sh')), 'legacy pruned');
assert.ok(!cmds.some(c => c.endsWith('bash-command-allowlist.sh')), 'legacy pruned');
assert.ok(!cmds.some(c => c.endsWith('some-removed-future-hook.sh')), 'dangling (non-legacy, missing file) pruned');
assert.ok(cmds.some(c => c.endsWith('commit-message-gate.sh')), 'shipped hook preserved (file exists after copy)');
assert.ok(cmds.includes('/opt/thirdparty/my-hook.sh'), 'third-party preserved');
assert.ok(after.hooks.PreToolUse.filter(g => g.matcher==='Agent').every(g => (g.hooks||[]).length>0), 'empty group dropped');
console.log('PRUNE_OK');
EOF

TESTS_RUN=$((TESTS_RUN + 1))
PRUNE_OUT=$(HOME="$PRUNE_HOME" node "$PRUNE_TEST" 2>&1 || true)
if echo "$PRUNE_OUT" | grep -q 'PRUNE_OK'; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} postinstall prunes dangling legacy registrations, preserves third-party hooks"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("postinstall prune: ${PRUNE_OUT:0:300}")
  echo "${CLR_FAIL}  ✗${CLR_RST} postinstall prunes dangling legacy registrations ${CLR_DIM}(${PRUNE_OUT:0:120})${CLR_RST}"
fi
rm -f "$PRUNE_TEST"; rm -rf "$PRUNE_HOME"
