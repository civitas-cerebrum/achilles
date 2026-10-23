// claude-code/register.js — the Claude Code step of postinstall: declare this package as a plugin
// marketplace and enable its one plugin, so the next session loads the plugin in place from
// node_modules (a relative-path plugin of a directory marketplace is read from its folder; an
// upgrade needs nothing). Nothing is copied anywhere.
//
// Local install (`npm install @civitas-cerebrum/achilles`): <project>/.claude/settings.local.json,
// because the marketplace path is this machine's. Global install (-g): ~/.claude/settings.json.
// Where `claude` >= 2.1.287 (the first build with mods) is on PATH, the CLI does the same write
// through `claude plugin marketplace add` + `claude plugin install`; any failure falls back to the
// settings merge. The merge is add-only: keys already present, ours or anyone's, are left alone,
// and a settings file that does not parse (JSONC included) is not touched. Never throws, never
// exits non-zero. ACHILLES_SKIP_CLAUDE_REGISTRATION=1 skips the whole step.
//
// `scope()` and `claudeVersion()` are the one install-context helper the postinstall steps and
// scripts/claude-plugin.mjs share.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MARKETPLACE = 'achilles';
const PLUGIN = 'achilles@achilles';
const CLAUDE_MIN = [2, 1, 287];
const TAG = '[@civitas-cerebrum/achilles]';

const thisPackageDir = fs.realpathSync(path.resolve(__dirname, '..'));

function realDir(p) {
  try { return fs.realpathSync(p); } catch { return path.resolve(p); }
}

// How npm invoked us. The consuming project is the path up to the FIRST node_modules segment of
// the package's real path (a hoisted or pnpm layout, node_modules/.pnpm/<pkg>/node_modules/<name>,
// still lands on the project), else INIT_CWD (an `npm install <folder>` links the folder, so only
// INIT_CWD names the project). -g exports npm_config_global=true; a package manager that exports
// no flag is read by whether a consumer package.json exists at that root.
function scope({ env = process.env, packageDir = thisPackageDir } = {}) {
  const parts = packageDir.split(path.sep);
  const nm = parts.indexOf('node_modules');
  const underNodeModules = nm !== -1;
  const initCwd = env.INIT_CWD ? path.resolve(env.INIT_CWD) : '';
  const projectRoot = underNodeModules ? parts.slice(0, nm).join(path.sep) || path.sep : initCwd || path.resolve(packageDir, '..');
  let isGlobal;
  if (env.npm_config_global === 'true') isGlobal = true;
  else if (env.npm_config_global === 'false') isGlobal = false;
  else isGlobal = underNodeModules && !fs.existsSync(path.join(projectRoot, 'package.json'));
  // A developer's `npm install` inside this checkout: npm ran in the package dir or below it and
  // the package is nobody's dependency. With no INIT_CWD npm did not start this run at all.
  let isOwnCheckout = false;
  if (!underNodeModules) {
    if (!initCwd) isOwnCheckout = true;
    else {
      const rel = path.relative(realDir(packageDir), realDir(initCwd));
      isOwnCheckout = rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
    }
  }
  return { isGlobal, isOwnCheckout, projectRoot, packageDir };
}

const settingsFile = ({ isGlobal, projectRoot }, home = os.homedir()) =>
  isGlobal ? path.join(home, '.claude', 'settings.json') : path.join(projectRoot, '.claude', 'settings.local.json');

// Add-only merge of the two keys; returns what changed, for the log.
function merge(settings, packageDir) {
  const changed = [];
  if (!settings.extraKnownMarketplaces || typeof settings.extraKnownMarketplaces !== 'object') settings.extraKnownMarketplaces = {};
  if (settings.extraKnownMarketplaces[MARKETPLACE] === undefined) {
    settings.extraKnownMarketplaces[MARKETPLACE] = { source: { source: 'directory', path: packageDir } };
    changed.push('extraKnownMarketplaces.achilles');
  }
  if (!settings.enabledPlugins || typeof settings.enabledPlugins !== 'object') settings.enabledPlugins = {};
  if (settings.enabledPlugins[PLUGIN] === undefined) {
    settings.enabledPlugins[PLUGIN] = true;
    changed.push(`enabledPlugins["${PLUGIN}"]`);
  }
  return changed;
}

function writeSettings(file, packageDir) {
  let settings = {};
  if (fs.existsSync(file)) {
    try {
      const raw = fs.readFileSync(file, 'utf8').trim();
      settings = raw ? JSON.parse(raw) : {};
      if (!settings || typeof settings !== 'object' || Array.isArray(settings)) throw new Error('not a JSON object');
    } catch (err) {
      return { status: 'unparsable', file, reason: err.message };
    }
  }
  const changed = merge(settings, packageDir);
  if (changed.length === 0) return { status: 'present', file };
  const known = settings.extraKnownMarketplaces[MARKETPLACE].source;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(settings, null, 2) + '\n');
  return { status: 'written', file, changed, stalePath: known && known.path !== packageDir ? known.path : undefined };
}

const defaultExec = (cmd, args, options) => spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options });

// The Claude Code CLI's version as [major, minor, patch], or null when `claude` is not on PATH.
function claudeVersion(exec = defaultExec) {
  const r = exec('claude', ['--version']);
  if (!r || r.error || r.status !== 0) return null;
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(String(r.stdout));
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

const atLeast = (v, min) => v !== null && (v[0] !== min[0] ? v[0] > min[0] : v[1] !== min[1] ? v[1] > min[1] : v[2] >= min[2]);

// The CLI route: both commands are script-safe and prompt-free for an ordinary plugin; `--scope
// local` writes the project's settings.local.json under its cwd, `--scope user` ~/.claude.
function viaCli(exec, { isGlobal, projectRoot, packageDir }) {
  const flags = ['--scope', isGlobal ? 'user' : 'local'];
  const cwd = isGlobal ? undefined : projectRoot;
  const add = exec('claude', ['plugin', 'marketplace', 'add', packageDir, ...flags], { cwd });
  if (!add || add.status !== 0) return false;
  const install = exec('claude', ['plugin', 'install', PLUGIN, ...flags], { cwd });
  return !!install && install.status === 0;
}

function register({ env = process.env, home = os.homedir(), packageDir = thisPackageDir, exec = defaultExec, log = console.log } = {}) {
  if (env.ACHILLES_SKIP_CLAUDE_REGISTRATION === '1') {
    log(`${TAG} Claude Code registration skipped (ACHILLES_SKIP_CLAUDE_REGISTRATION=1).`);
    return { status: 'skipped' };
  }
  const s = scope({ env, packageDir });
  if (s.isOwnCheckout) return { status: 'own-checkout' };
  const manual = `claude plugin marketplace add ${packageDir} && claude plugin install ${PLUGIN}`;
  try {
    const version = claudeVersion(exec);
    if (atLeast(version, CLAUDE_MIN) && viaCli(exec, s)) {
      log(`${TAG} Claude Code: plugin installed in place from ${packageDir} (${s.isGlobal ? 'user' : 'local'} scope). It loads at the next session.`);
      return { status: 'cli', scope: s.isGlobal ? 'user' : 'local' };
    }
    const result = writeSettings(settingsFile(s, home), packageDir);
    if (result.status === 'unparsable') {
      log(`${TAG} Claude Code: ${result.file} does not parse (${result.reason}); left untouched. Register by hand: ${manual}`);
    } else if (result.status === 'present') {
      log(`${TAG} Claude Code: plugin already declared in ${result.file}.`);
    } else {
      log(`${TAG} Claude Code: plugin declared in ${result.file} (${result.changed.join(', ')}); it loads at the next session.${result.stalePath ? ` Note: the marketplace entry points at ${result.stalePath}, not ${packageDir}.` : ''}`);
    }
    if (version === null) log(`${TAG} \`claude\` is not on PATH; if Claude Code is installed elsewhere run: ${manual}. Not using Claude Code? ACHILLES_SKIP_CLAUDE_REGISTRATION=1 skips this step.`);
    return result;
  } catch (err) {
    log(`${TAG} Claude Code registration failed (${err.message}). Register by hand: ${manual}`);
    return { status: 'failed', reason: err.message };
  }
}

module.exports = { register, scope, merge, writeSettings, settingsFile, claudeVersion, atLeast, CLAUDE_MIN, PLUGIN, MARKETPLACE };

if (require.main === module) register();
