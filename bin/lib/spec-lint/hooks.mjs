// The pre-commit check of the test baseline: a small shell script that runs `achilles-spec-lint --pre-commit`
// from the project's own install, blocks the commit only on findings (exit 1), and lets it through with a
// warning when the lint cannot run (not installed, no node, any other exit): CI is the gate people meet.
//
// Installing never overwrites a hook:
//   githooks   no hooks path and no active pre-commit: `.githooks/pre-commit` (committed with the baseline) and
//              `core.hooksPath` set to `.githooks`
//   chained    an existing pre-commit (husky's `.husky/pre-commit`, a custom `core.hooksPath` directory, the
//              default hooks directory): the script goes next to it as `achilles-pre-commit` and one line is
//              appended to the pre-commit that calls it
//   wrapped    the existing pre-commit is not a shell script, or it exits or execs before its end: it is moved
//              to `pre-commit.achilles-original` and a new pre-commit runs the check, then the original
//   lefthook   a lefthook configuration: a `pre-commit` command that runs the script is added to it
// Running it again changes nothing.
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parseDocument } from 'yaml';
import { gitSync } from './git.mjs';

export const MARKER = '# achilles-pre-commit';
const ORIGINAL = 'pre-commit.achilles-original';
const LEFTHOOK = ['lefthook.yml', 'lefthook.yaml', '.lefthook.yml', '.lefthook.yaml'];
const PKG = '@civitas-cerebrum/achilles';

export class HookError extends Error {}

const git = (root, args) => gitSync(root, args).trim();
const posix = (p) => p.split(path.sep).join('/');

/** The hook script for a project at `rel` (from the top level of its work tree; '' for the top level). */
export function hookScript(rel) {
  const dir = rel ? `$top/${rel}` : '$top';
  return `#!/bin/sh
${MARKER}: the test-baseline check of the staged change (achilles-spec-lint --pre-commit).
# Installed by \`npx achilles-spec-lint --init-baseline\` or \`--install-hook\`. It blocks a commit only on
# blocking findings in touched tests or a ratchet violation; when the lint cannot run it warns and the
# commit goes ahead (CI checks the change again).
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$(pwd)"
dir="${dir}"
case "\${GIT_INDEX_FILE:-}" in ''|/*) ;; *) GIT_INDEX_FILE="$(pwd)/$GIT_INDEX_FILE"; export GIT_INDEX_FILE ;; esac
case "\${GIT_DIR:-}" in ''|/*) ;; *) GIT_DIR="$(pwd)/$GIT_DIR"; export GIT_DIR ;; esac
lint="$dir/node_modules/${PKG}/bin/spec-lint.mjs"
if [ ! -f "$lint" ] || ! command -v node >/dev/null 2>&1; then
  echo "achilles-pre-commit: warning: the test-baseline check did not run (${PKG} is not installed in $dir; run npm ci). The commit goes ahead; CI still checks it." >&2
  exit 0
fi
CLAUDE_PROJECT_DIR="$dir" node "$lint" --pre-commit
status=$?
if [ "$status" -eq 1 ]; then exit 1; fi
if [ "$status" -ne 0 ]; then
  echo "achilles-pre-commit: warning: the test-baseline check could not run (exit $status). The commit goes ahead; CI still checks it." >&2
fi
exit 0
`;
}

const HEADLINE = `${MARKER}: the test-baseline check of the staged change`;
const isOurs = (text) => text.includes(HEADLINE);

const callLine = (scriptFromTop) => `${MARKER}: the test-baseline check\nsh "$(git rev-parse --show-toplevel)/${scriptFromTop}" || exit 1\n`;

const isShell = (text) => { const m = /^#!\s*(\S+)(?:\s+(\S+))?/.exec(text); if (!m) return true; const bin = path.basename(m[1]) === 'env' ? m[2] || '' : path.basename(m[1]); return /^(sh|bash|dash|zsh|ksh)$/.test(bin); };
const endsEarly = (text) => text.split('\n').some((l) => /^\s*(exit|exec)\b/.test(l));

function write(abs, text) {
  mkdirSync(path.dirname(abs), { recursive: true });
  const before = existsSync(abs) ? readFileSync(abs, 'utf8') : null;
  if (before !== text) writeFileSync(abs, text);
  chmodSync(abs, 0o755);
  return before !== text;
}

/** Appends the call to an existing pre-commit, or wraps it; nothing when it already calls the check. */
function chain(file, scriptFromTop, top) {
  const text = existsSync(file) ? readFileSync(file, 'utf8') : null;
  if (text === null) return { mode: 'chained', changed: write(file, `#!/bin/sh\n${callLine(scriptFromTop)}`) };
  if (text.includes(MARKER)) return { mode: existsSync(path.join(path.dirname(file), ORIGINAL)) ? 'wrapped' : 'chained', changed: false };
  if (isShell(text) && !endsEarly(text)) {
    writeFileSync(file, `${text}${text.endsWith('\n') ? '' : '\n'}\n${callLine(scriptFromTop)}`);
    chmodSync(file, 0o755);
    return { mode: 'chained', changed: true };
  }
  const original = path.join(path.dirname(file), ORIGINAL);
  if (existsSync(original)) throw new HookError(`${posix(path.relative(top, original))} already exists: move it away, then install again`);
  renameSync(file, original);
  const originalFromTop = posix(path.relative(top, original));
  write(file, `#!/bin/sh\n${callLine(scriptFromTop)}exec "$(git rev-parse --show-toplevel)/${originalFromTop}" "$@"\n`);
  return { mode: 'wrapped', changed: true };
}

function lefthook(top, configFile, scriptFromTop) {
  const text = readFileSync(configFile, 'utf8');
  if (text.includes('achilles-pre-commit')) return false;
  const doc = parseDocument(text);
  doc.setIn(['pre-commit', 'commands', 'achilles-test-baseline', 'run'], `sh ${scriptFromTop}`);
  writeFileSync(configFile, String(doc));
  return true;
}

/**
 * Installs the pre-commit check for the project at `root`. Returns { mode, path, changed, notes } where `path`
 * is the file a commit runs (from the top level) and `notes` say what to commit or keep in mind.
 */
export function installHook(root) {
  let top;
  try { top = git(root, ['rev-parse', '--show-toplevel']); } catch { throw new HookError(`${root} is not in a git work tree`); }
  const rel = posix(path.relative(top, root));
  const script = hookScript(rel);
  let hooksPath = '';
  try { hooksPath = git(root, ['config', '--get', 'core.hooksPath']); } catch { /* unset */ }
  const notes = [];
  const lh = LEFTHOOK.map((f) => path.join(top, f)).find(existsSync);
  if (lh) {
    const at = path.join(path.dirname(lh), '.lefthook', 'achilles-pre-commit');
    const fromTop = posix(path.relative(top, at));
    const wrote = write(at, script);
    const edited = lefthook(top, lh, fromTop);
    notes.push(`commit ${fromTop} and ${posix(path.relative(top, lh))}; run \`lefthook install\` if lefthook is not installed in this clone`);
    return { mode: 'lefthook', path: posix(path.relative(top, lh)), changed: wrote || edited, notes };
  }
  if (!hooksPath) {
    const hooksDir = path.resolve(root, git(root, ['rev-parse', '--git-path', 'hooks']));
    const active = path.join(hooksDir, 'pre-commit');
    if (existsSync(active)) {
      // a hook in the default directory (written by a tool or by hand): chain into it rather than hide it
      const at = path.join(hooksDir, 'achilles-pre-commit');
      write(at, script);
      const r = chain(active, posix(path.relative(top, at)), top);
      notes.push('the check sits in the local hooks directory, which is not committed: run `npx achilles-spec-lint --install-hook` in every clone');
      return { mode: r.mode, path: posix(path.relative(top, active)), changed: r.changed, notes };
    }
    const file = path.join(top, '.githooks', 'pre-commit');
    let changed;
    if (existsSync(file) && !isOurs(readFileSync(file, 'utf8'))) {
      const at = path.join(top, '.githooks', 'achilles-pre-commit');
      changed = write(at, script);
      changed = chain(file, posix(path.relative(top, at)), top).changed || changed;
    } else changed = write(file, script);
    gitSync(top, ['config', 'core.hooksPath', '.githooks']);
    notes.push('commit .githooks/ with the baseline; every other clone runs `npx achilles-spec-lint --install-hook` once (git does not clone core.hooksPath)');
    return { mode: 'githooks', path: '.githooks/pre-commit', changed, notes };
  }
  const dir = path.resolve(top, hooksPath);
  // husky: core.hooksPath is .husky/_ (v9, generated) or .husky (v4 to v8); the project's own file is .husky/pre-commit
  const hp = posix(hooksPath).replace(/\/+$/, '');
  const home = /(^|\/)\.husky\/_$/.test(hp) ? path.dirname(dir) : dir;
  const own = path.join(home, 'pre-commit');
  if (existsSync(own) && isOurs(readFileSync(own, 'utf8'))) {
    // the hooks path names a directory whose pre-commit is this check (the committed .githooks, a clone that ran it before)
    return { mode: 'githooks', path: posix(path.relative(top, own)), changed: write(own, script), notes };
  }
  const at = path.join(home, 'achilles-pre-commit');
  let changed = write(at, script);
  const r = chain(path.join(home, 'pre-commit'), posix(path.relative(top, at)), top);
  changed = r.changed || changed;
  if (within(top, home)) notes.push(`commit ${posix(path.relative(top, at))} and ${posix(path.relative(top, path.join(home, 'pre-commit')))} with the baseline`);
  return { mode: r.mode, path: posix(path.relative(top, path.join(home, 'pre-commit'))), changed, notes };
}

const within = (a, b) => { const r = path.relative(a, b); return !r.startsWith('..') && !path.isAbsolute(r); };
