// The git views the baseline commands lint: HEAD (an init reads only the committed suite), the index (the
// pre-commit check lints what the commit will hold, also under a temporary index such as `git commit -a`
// uses), and the facts the ratchet needs (the baseline at a revision, the renames since it was written).
// A view is { tracked, contents }: the paths that exist in it and their text where it differs from the disk.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { gitSync, catBlobs } from './git.mjs';
import { BASELINE_FILE } from './ids.mjs';

const git = (root, args) => gitSync(root, args);
const z = (s) => s.split('\0').filter(Boolean);

/** The path of `root` inside its work tree ('' at the top level, else ending in '/'). */
export const prefixOf = (root) => git(root, ['rev-parse', '--show-prefix']).trim();

/** The commit HEAD names, or null on an unborn branch. */
export function headCommit(root) {
  try { return git(root, ['rev-parse', '--verify', '-q', 'HEAD']).trim() || null; } catch { return null; }
}

/** The baseline file's text at `rev` (a commit, or `:` for the index), or null when it is not there. */
export function baselineAt(root, rev) {
  try { return git(root, ['show', `${rev}:./${BASELINE_FILE}`]); } catch { return null; }
}

/** The last commit in `rev`'s history that changed the baseline file, or null. */
export function baselineCommit(root, rev) {
  try { return git(root, ['log', '-1', '--format=%H', rev, '--', BASELINE_FILE]).trim() || null; } catch { return null; }
}

/** True when the baseline file is in HEAD's history at all (added, changed or deleted by some ancestor). */
export function baselineInHistory(root) {
  return !!headCommit(root) && !!baselineCommit(root, 'HEAD');
}

/** Renames since `from` (old rel → new rel): to the index with `cached`, else to the working tree. */
export function renamesSince(root, from, { cached = false } = {}) {
  const out = new Map();
  if (!from) return out;
  const parts = z(git(root, ['diff', '-M', '--name-status', '-z', '--relative', ...(cached ? ['--cached'] : []), from]));
  for (let i = 0; i < parts.length; i++) {
    const s = parts[i];
    if (/^[RC]\d*$/.test(s)) { if (s.startsWith('R')) out.set(parts[i + 1], parts[i + 2]); i += 2; } else i += 1;
  }
  return out;
}

/** The files of HEAD under `root`, and the committed text of those that differ on disk. */
export function headView(root) {
  const prefix = prefixOf(root);
  const tracked = new Set(z(git(root, ['ls-tree', '-r', '-z', '--name-only', '--full-tree', 'HEAD'])).filter((p) => p.startsWith(prefix)).map((p) => p.slice(prefix.length)));
  const differ = z(git(root, ['diff', '--name-only', '-z', '--relative', 'HEAD'])).filter((p) => tracked.has(p));
  const blobs = catBlobs(root, differ.map((p) => `HEAD:${prefix}${p}`));
  return { tracked, contents: new Map(differ.map((p) => [p, blobs.get(`HEAD:${prefix}${p}`)]).filter(([, t]) => typeof t === 'string')), from: 'HEAD' };
}

/** The files of the index under `root`, and the staged text of those that differ on disk. */
export function indexView(root) {
  const prefix = prefixOf(root);
  const tracked = new Set(z(git(root, ['ls-files', '-z'])));
  const differ = z(git(root, ['diff', '--name-only', '-z', '--relative'])).filter((p) => tracked.has(p));
  const blobs = catBlobs(root, differ.map((p) => `:${prefix}${p}`));
  return { tracked, contents: new Map(differ.map((p) => [p, blobs.get(`:${prefix}${p}`)]).filter(([, t]) => typeof t === 'string')), from: 'the index' };
}

const hashFile = (abs) => {
  try {
    const st = statSync(abs);
    if (!st.isFile()) return 'dir';
    if (st.size > 1024 * 1024) return `size:${st.size}:${st.mtimeMs}`;
    return createHash('sha1').update(readFileSync(abs)).digest('hex');
  } catch { return 'missing'; }
};

/**
 * What the lint's result depends on, by git object id: every index entry (`git ls-files -s`), the disk content
 * of the files that differ from the index and of the untracked ones, the local `.env` and the installed
 * framework's version. Equal parts, equal result.
 */
export function contentKeyParts(root) {
  const staged = git(root, ['ls-files', '-s', '-z']);
  const disk = [...z(git(root, ['diff', '--name-only', '-z', '--relative'])), ...z(git(root, ['ls-files', '--others', '--exclude-standard', '-z']))]
    .sort().map((p) => `${p}\0${hashFile(path.join(root, p))}`);
  const pkg = path.join(root, 'node_modules', '@civitas-cerebrum', 'element-interactions', 'package.json');
  const env = path.join(root, '.env');
  return [staged, disk.join('\n'), existsSync(pkg) ? hashFile(pkg) : '-', existsSync(env) ? hashFile(env) : '-'].join('\n\u0001\n');
}
