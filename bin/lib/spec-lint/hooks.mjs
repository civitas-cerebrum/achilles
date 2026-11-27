// The pre-commit check of the test baseline: a small shell script that runs `achilles-spec-lint --pre-commit`
// from the project's own install, blocks the commit only on findings (exit 1), and lets it through with a
// warning when the lint cannot run (not installed, no node, any other exit): CI is the gate people meet.
//
// Installing never overwrites a hook:
//   githooks   no hooks path, no active hook in the local hooks directory: `.githooks/pre-commit` (committed with
//              the baseline) and the local `core.hooksPath` set to `.githooks`. Refused when `.githooks` holds a
//              hook that is not this check (setting the path would turn it on) unless `--activate-hooks` names it
//   chained    an existing hooks setup (husky's `.husky/pre-commit`, a `core.hooksPath` directory inside the work
//              tree, a local hooks directory with any active hook): the script goes next to it as
//              `achilles-pre-commit`, and the pre-commit calls it first, right after its shebang line, so the
//              hook's own commands and final status are kept
//   wrapped    the existing pre-commit is not a shell script: it is moved to `pre-commit.achilles-original`
//              and a new pre-commit runs the check, then the original
//   lefthook   a lefthook configuration and no hooks path: a `pre-commit` command that runs the script
//   shared     a hooks path outside the work tree (a global or system setting, a shared directory): nothing is
//              written there; the check is written to `.githooks/achilles-pre-commit` (committed) and the one
//              line to add to the shared pre-commit by hand is printed
// The installer never writes outside the repository. Running it again changes nothing. One repository's
// script serves one project: installing a second project where the script runs another one's check is refused
// (the message names that project).
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parseDocument } from 'yaml';
import { gitSync } from './git.mjs';

export const MARKER = '# achilles-pre-commit';
const ORIGINAL = 'pre-commit.achilles-original';
const LEFTHOOK = ['lefthook.yml', 'lefthook.yaml', '.lefthook.yml', '.lefthook.yaml'];
const PKG = '@civitas-cerebrum/achilles';

export class HookError extends Error {
  constructor(message, { written = [], todo = null } = {}) { super(message); this.written = written; this.todo = todo; }
}

/** The script a shared hooks directory calls: committed in the repository, absent in every other one. */
export const SHARED_SCRIPT = '.githooks/achilles-pre-commit';
/** The one line for a shared (global, system or outside) pre-commit: runs the repository's own check, skips where there is none. */
export const SHARED_LINE = `s="$(git rev-parse --show-toplevel)/${SHARED_SCRIPT}"; [ ! -f "$s" ] || sh "$s" || exit 1`;

const git = (root, args) => gitSync(root, args).trim();
const posix = (p) => p.split(path.sep).join('/');

/** The hook script for a project at `rel` (from the top level of its work tree; '' for the top level). */
export function hookScript(rel) {
  if (path.isAbsolute(rel) || rel.split('/').includes('..')) throw new HookError(`the project's place in the repository (${rel}) is not a path inside it`);
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
# the project's install, or a workspace root's above it (hoisted), never above the work tree
lint=""
d="$dir"
while :; do
  if [ -f "$d/node_modules/${PKG}/bin/spec-lint.mjs" ]; then lint="$d/node_modules/${PKG}/bin/spec-lint.mjs"; break; fi
  [ "$d" = "$top" ] && break
  case "$d" in "$top"/*) d="$(dirname "$d")" ;; *) break ;; esac
done
if [ -z "$lint" ] || ! command -v node >/dev/null 2>&1; then
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
/** The project an installed script runs the check of ('' for the top level), or null when it names none. */
export function servedProject(text) {
  const m = /^dir="\$top(?:\/(.*))?"$/m.exec(text);
  return m ? m[1] || '' : null;
}
const projectName = (rel) => (rel ? `the project in ${rel}` : 'the project at the top level');
const SCRIPT = 'achilles-pre-commit';

/** Every hook name git runs (a file of another name in a hooks directory is not a hook). */
const HOOK_NAMES = new Set(['applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit', 'prepare-commit-msg', 'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push', 'pre-receive', 'update', 'proc-receive', 'post-receive', 'post-update', 'reference-transaction', 'push-to-checkout', 'pre-auto-gc', 'post-rewrite', 'sendemail-validate', 'fsmonitor-watchman', 'post-index-change', 'p4-changelist', 'p4-prepare-changelist', 'p4-post-changelist', 'p4-pre-submit']);

const within = (a, b) => { const r = path.relative(a, b); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)); };

/** The shell words that name a script: from the top level when it sits in the work tree, else its absolute path. */
const scriptRef = (top, abs) => (within(top, abs) ? `"$(git rev-parse --show-toplevel)/${posix(path.relative(top, abs))}"` : `"${abs}"`);
const callLine = (ref) => `${MARKER}: the test-baseline check\nsh ${ref} || exit 1\n`;

const isShell = (text) => { const m = /^#!\s*(\S+)(?:\s+(\S+))?/.exec(text); if (!m) return true; const bin = path.basename(m[1]) === 'env' ? m[2] || '' : path.basename(m[1]); return /^(sh|bash|dash|zsh|ksh)$/.test(bin); };

/** The hooks in a directory: files named as git hooks (not `.sample`), other than this check. */
function hooksIn(dir) {
  if (!existsSync(dir)) return [];
  const names = readdirSync(dir);
  // on a case-insensitive file system `PRE-COMMIT` is the pre-commit git runs: names compare case-insensitively there
  const folds = (f) => f !== f.toLowerCase() && !names.includes(f.toLowerCase()) && existsSync(path.join(dir, f.toLowerCase()));
  return [...new Set(names.filter((f) => (HOOK_NAMES.has(f) || (HOOK_NAMES.has(f.toLowerCase()) && folds(f))) && statSync(path.join(dir, f)).isFile() && !isOurs(readFileSync(path.join(dir, f), 'utf8'))).map((f) => (HOOK_NAMES.has(f) ? f : f.toLowerCase())))].sort();
}

/**
 * Refuses a write that could land outside the repository: the path (by name) and the real path of its nearest
 * existing directory must sit in the work tree or the git common directory, and neither the file nor any
 * existing directory between it and that root may be a symbolic link (a planted link would redirect the write).
 */
function guardFor(top, common) {
  const realTop = realpathSync(top);
  const realCommon = realpathSync(common);
  return (abs) => {
    const base = within(top, abs) ? top : within(common, abs) ? common : null;
    if (!base) throw new HookError(`refusing to write ${abs}: it is outside this repository`);
    for (let p = abs; p !== base && within(base, p); p = path.dirname(p)) {
      let st = null;
      try { st = lstatSync(p); } catch { continue; }
      if (st.isSymbolicLink()) throw new HookError(`refusing to write ${abs}: ${p} is a symbolic link, which could send the write outside the repository; replace it with a real file or directory`);
    }
    let dir = path.dirname(abs);
    while (!existsSync(dir)) dir = path.dirname(dir);
    const real = realpathSync(dir);
    if (!within(realTop, real) && !within(realCommon, real)) throw new HookError(`refusing to write ${abs}: its directory resolves to ${real}, outside this repository`);
  };
}

/**
 * Writes through a temporary file in the same directory renamed over the target: a hard link to a file
 * elsewhere is replaced, never written into, and the window for a link planted mid-write is narrow.
 */
function replace(abs, text) {
  const tmp = path.join(path.dirname(abs), `.${path.basename(abs)}.achilles-${process.pid}.tmp`);
  writeFileSync(tmp, text, { mode: 0o755, flag: 'wx' });
  renameSync(tmp, abs);
  chmodSync(abs, 0o755);
}

function write(abs, text) {
  mkdirSync(path.dirname(abs), { recursive: true });
  const before = existsSync(abs) ? readFileSync(abs, 'utf8') : null;
  if (before !== text || (existsSync(abs) && lstatSync(abs).nlink > 1)) replace(abs, text);
  else chmodSync(abs, 0o755);
  return before !== text;
}


/**
 * Puts the call into an existing pre-commit right after its shebang line, so the hook's own commands and its
 * final status are kept (an early `exit 0` cannot skip the check), or wraps a hook that is not a shell script;
 * nothing when it already calls the check.
 */
function chain(file, ref, top, guard) {
  guard(file);
  const text = existsSync(file) ? readFileSync(file, 'utf8') : null;
  if (text === null) return { mode: 'chained', changed: write(file, `#!/bin/sh\n${callLine(ref)}`) };
  if (text.includes(MARKER)) return { mode: existsSync(path.join(path.dirname(file), ORIGINAL)) ? 'wrapped' : 'chained', changed: false };
  if (isShell(text)) {
    const body = text.startsWith('#!') && !text.includes('\n') ? `${text}\n` : text;
    const at = body.startsWith('#!') ? body.indexOf('\n') + 1 : 0;
    replace(file, `${body.slice(0, at)}${callLine(ref)}${body.slice(at)}`);
    return { mode: 'chained', changed: true };
  }
  const original = path.join(path.dirname(file), ORIGINAL);
  guard(original);
  if (existsSync(original)) throw new HookError(`${posix(path.relative(top, original))} already exists: move it away, then install again`);
  renameSync(file, original);
  write(file, `#!/bin/sh\n${callLine(ref)}exec ${scriptRef(top, original)} "$@"\n`);
  return { mode: 'wrapped', changed: true };
}

function lefthook(configFile, scriptFromTop) {
  const text = readFileSync(configFile, 'utf8');
  if (text.includes(SCRIPT)) return false;
  const doc = parseDocument(text);
  doc.setIn(['pre-commit', 'commands', 'achilles-test-baseline', 'run'], `sh ${scriptFromTop}`);
  const tmp = path.join(path.dirname(configFile), `.${path.basename(configFile)}.achilles-${process.pid}.tmp`);
  writeFileSync(tmp, String(doc), { flag: 'wx' });
  renameSync(tmp, configFile);
  return true;
}

const configGet = (root, scope) => { try { return git(root, ['config', ...scope, '--get', 'core.hooksPath']); } catch { return ''; } };

/**
 * Installs the pre-commit check for the project at `root`. Returns { mode, path, changed, notes, committed }:
 * `path` is the file a commit runs (from the top level), `committed` whether it sits in the work tree (it is
 * committed with the baseline), `notes` what to commit or keep in mind. `activate` names the hooks under
 * `.githooks` the person accepts turning on. Throws HookError rather than write outside the repository.
 */
export function installHook(root, { activate = [] } = {}) {
  let top;
  let common;
  try {
    // real paths on both sides: a project reached through a symbolic link (a linked workspace, /tmp on macOS)
    // must give the same committed hook as one reached directly
    root = realpathSync(root);
    top = realpathSync(git(root, ['rev-parse', '--show-toplevel']));
    common = realpathSync(path.resolve(root, git(root, ['rev-parse', '--git-common-dir'])));
  } catch { throw new HookError(`${root} is not in a git work tree`); }
  if (!within(top, root)) throw new HookError(`the project ${root} is not inside its git work tree ${top}`);
  const guard = guardFor(top, common);
  const rel = posix(path.relative(top, root));
  const script = hookScript(rel);
  const fromTop = (abs) => posix(path.relative(top, abs));
  // the check script: written only where none runs another project's check (same project: idempotent)
  const put = (abs, text) => {
    guard(abs);
    if (text === script && existsSync(abs)) {
      const was = readFileSync(abs, 'utf8');
      const served = isOurs(was) ? servedProject(was) : null;
      if (served !== null && served !== rel) {
        throw new HookError(`${fromTop(abs)} already runs the check of ${projectName(served)}: one repository's check script serves one project, so installing ${projectName(rel)} would switch that one off`, { todo: `keep the check of ${projectName(served)}, or, when that project moved or no longer records a baseline, delete ${fromTop(abs)} and run \`achilles-spec-lint --install-hook\` again; CI still checks every change` });
      }
    }
    return write(abs, text);
  };
  const notes = [];
  const effective = configGet(root, []);
  if (effective) {
    const local = configGet(root, ['--local']);
    const dir = path.resolve(top, effective.replace(/^~(?=\/|$)/, process.env.HOME || '/'));
    if (!within(top, dir) || effective !== local) {
      // the shared directory is left alone (read, never written); the check itself is committed here, and the
      // line that calls it skips every repository that has none (the script finds the project, a hoisted
      // install, and fails open)
      const changed = put(path.join(top, SHARED_SCRIPT), script);
      let calls = false;
      try { calls = readFileSync(path.join(dir, 'pre-commit'), 'utf8').includes(SHARED_SCRIPT); } catch { /* no shared pre-commit yet */ }
      notes.push(`core.hooksPath is ${effective}${effective !== local ? ', set outside this repository (a global or system setting)' : ', outside this work tree'}: nothing is written there, since it serves every repository that uses it`);
      notes.push(calls ? `the shared pre-commit already calls it (${SHARED_SCRIPT})` : `installed the committed check; add this line to your shared hook: ${SHARED_LINE}`);
      notes.push(`commit ${SHARED_SCRIPT} with the baseline`);
      return { mode: 'shared', path: SHARED_SCRIPT, changed, notes, committed: true, extra: [] };
    }
    // husky: core.hooksPath is .husky/_ (v9, generated) or .husky (v4 to v8); the project's own file is .husky/pre-commit
    const hp = posix(effective).replace(/\/+$/, '');
    const home = /(^|\/)\.husky\/_$/.test(hp) ? path.dirname(dir) : dir;
    const own = path.join(home, 'pre-commit');
    if (existsSync(own) && isOurs(readFileSync(own, 'utf8'))) return { mode: 'githooks', path: fromTop(own), changed: put(own, script), notes, committed: true, extra: [] };
    const at = path.join(home, SCRIPT);
    let changed = put(at, script);
    const r = chain(own, scriptRef(top, at), top, guard);
    changed = r.changed || changed;
    notes.push(`commit ${fromTop(at)} and ${fromTop(own)} with the baseline`);
    // the committed .githooks keeps its label however many runs it took
    return { mode: home === path.join(top, '.githooks') ? 'githooks' : r.mode, path: fromTop(own), changed, notes, committed: true, extra: [fromTop(at)] };
  }
  const lh = LEFTHOOK.map((f) => path.join(top, f)).find(existsSync);
  if (lh) {
    const at = path.join(path.dirname(lh), '.lefthook', SCRIPT);
    const wrote = put(at, script);
    guard(lh);
    const edited = lefthook(lh, fromTop(at));
    notes.push(`commit ${fromTop(at)} and ${fromTop(lh)}; run \`lefthook install\` if lefthook is not installed in this clone`);
    return { mode: 'lefthook', path: fromTop(lh), changed: wrote || edited, notes, committed: true, extra: [fromTop(at)] };
  }
  const hooksDir = path.resolve(root, git(root, ['rev-parse', '--git-path', 'hooks']));
  const active = hooksIn(hooksDir);
  if (active.length) {
    // hooks already run from the local directory (a tool's or the person's): a hooks path would switch them off
    const at = path.join(hooksDir, SCRIPT);
    put(at, script);
    const r = chain(path.join(hooksDir, 'pre-commit'), scriptRef(top, at), top, guard);
    notes.push(`the local hooks directory already runs ${active.join(', ')}, so the check is chained there; it is not committed: run \`npx achilles-spec-lint --install-hook\` in every clone`);
    return { mode: r.mode, path: posix(path.relative(top, path.join(hooksDir, 'pre-commit'))), changed: r.changed, notes, committed: false, extra: [] };
  }
  const dotHooks = path.join(top, '.githooks');
  const dormant = hooksIn(dotHooks);
  const unaccepted = dormant.filter((h) => !activate.includes(h));
  if (unaccepted.length) throw new HookError(`.githooks holds ${unaccepted.join(', ')}, which git does not run today: setting core.hooksPath to .githooks would turn ${unaccepted.length === 1 ? 'it' : 'them'} on. Pass \`--activate-hooks ${unaccepted.join(',')}\` to accept that, or move ${unaccepted.length === 1 ? 'it' : 'them'} away`);
  const file = path.join(dotHooks, 'pre-commit');
  let changed;
  if (dormant.includes('pre-commit')) {
    const at = path.join(dotHooks, SCRIPT);
    changed = put(at, script);
    changed = chain(file, scriptRef(top, at), top, guard).changed || changed;
  } else changed = put(file, script);
  gitSync(top, ['config', '--local', 'core.hooksPath', '.githooks']);
  notes.push('commit .githooks/ with the baseline; every other clone runs `npx achilles-spec-lint --install-hook` once (git does not clone core.hooksPath)');
  return { mode: 'githooks', path: '.githooks/pre-commit', changed, notes, committed: true, extra: [] };
}
