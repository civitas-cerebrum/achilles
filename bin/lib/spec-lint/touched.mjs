// What a change touches (test-baseline.md §Severity: only the touched test must be clean).
//
// `--staged` compares the index with HEAD; `--base <ref>` compares the working tree (plus untracked files)
// with the merge-base of HEAD and <ref>. A change is a map rel → { status, lines } where `lines` holds the
// changed line numbers of the new side (null for a new file). A finding is touched when the unit it sits
// in is touched:
//   test, hook, helper   its line range holds a changed line (or the file is new)
//   describe scope       a changed line inside the describe that no test, hook, helper or nested describe holds
//   file scope           a changed line outside every unit and describe
import { gitSync } from './git.mjs';

const git = (root, args) => gitSync(root, args);

export class ChangeError extends Error {}

/** Parses `git diff -U0` output into rel → { status, lines }. */
export function parseDiff(text) {
  const out = new Map();
  let cur = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) { cur = { status: 'M', lines: new Set(), path: null }; continue; }
    if (!cur) continue;
    if (line.startsWith('new file mode')) cur.status = 'A';
    else if (line.startsWith('deleted file mode')) cur.status = 'D';
    else if (line.startsWith('rename to ')) { cur.status = 'R'; cur.path = line.slice(10); }
    else if (line.startsWith('+++ ')) {
      const p = line.slice(4);
      if (p !== '/dev/null') cur.path = p.replace(/^b\//, '');
      if (cur.path) out.set(cur.path, cur);
    } else if (line.startsWith('@@')) {
      const m = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.exec(line);
      if (!m) continue;
      const start = Number(m[1]);
      const count = m[2] === undefined ? 1 : Number(m[2]);
      if (count === 0) { cur.lines.add(Math.max(start, 1)); cur.lines.add(start + 1); } // a deletion after line `start`
      for (let l = start; l < start + count; l++) cur.lines.add(l);
    }
  }
  for (const [p, c] of out) {
    if (c.status === 'A') out.set(p, { status: 'A', lines: null });
    else out.set(p, { status: c.status, lines: c.lines });
  }
  return out;
}

/** Throws a ChangeError naming the directory when it is not inside a git work tree. */
function workTree(root) {
  let inside = '';
  try { inside = git(root, ['rev-parse', '--is-inside-work-tree']).trim(); } catch { /* not a repository */ }
  if (inside !== 'true') throw new ChangeError(`${root} is not a git work tree`);
}

/** The staged change: index versus HEAD, with each changed file's staged content. */
export function stagedChange(root) {
  workTree(root);
  let diff;
  try { diff = git(root, ['diff', '--cached', '--no-color', '--no-ext-diff', '-U0', '-M', '--relative']); } catch (e) { throw new ChangeError(`git diff --cached failed: ${String(e.stderr || e.message).trim()}`); }
  const files = parseDiff(diff);
  const contents = new Map();
  const before = new Map();
  for (const [rel, c] of files) {
    if (c.status === 'D') continue;
    try { contents.set(rel, git(root, ['show', `:./${rel}`])); } catch { /* not readable from the index: the working tree is used */ }
    if (c.status === 'M') try { before.set(rel, git(root, ['show', `HEAD:./${rel}`])); } catch { /* no base version */ }
  }
  return { files, contents, before, from: 'the index against HEAD' };
}

/** The change against the merge-base of HEAD and `ref`: the working tree, plus untracked files as new files. */
export function baseChange(root, ref) {
  workTree(root);
  let mb;
  try { mb = git(root, ['merge-base', 'HEAD', ref]).trim(); } catch (e) { throw new ChangeError(`no merge-base of HEAD and ${ref}: ${String(e.stderr || e.message).trim()}`); }
  const files = parseDiff(git(root, ['diff', '--no-color', '--no-ext-diff', '-U0', '-M', '--relative', mb]));
  for (const rel of git(root, ['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean)) if (!files.has(rel)) files.set(rel, { status: 'A', lines: null });
  const before = new Map();
  for (const [rel, c] of files) if (c.status === 'M') try { before.set(rel, git(root, ['show', `${mb}:./${rel}`])); } catch { /* no base version */ }
  return { files, contents: new Map(), before, from: `the working tree against ${ref} (merge-base ${mb.slice(0, 12)})` };
}

const inRange = (l, u) => l >= u.line && l <= u.endLine;

/**
 * Marks every finding of `project` with `touched` (true / false) from `change.files`.
 * `units` per file: tests (call ranges), hooks and helpers (function ranges), describes (call ranges).
 */
export function markTouched(project, change) {
  for (const f of project.findings) {
    const file = project.byRel.get(f.file);
    const c = change.files.get(f.file);
    if (!c || c.status === 'D') { f.touched = false; continue; }
    if (c.lines === null) { f.touched = true; continue; }
    // a finding may name the other lines that make it (a generated test's loop and table, a helper's users)
    const extra = f.data && Array.isArray(f.data.ranges) ? f.data.ranges : [];
    // `lostUser`: the change took away a use the base version had (a helper's second user)
    f.touched = touchedAt(file, f, c.lines) || !!(f.data && f.data.lostUser) || [...c.lines].some((l) => extra.some(([s, e]) => l >= s && l <= e));
  }
}

function touchedAt(file, f, lines) {
  const changed = [...lines];
  if (!file) return changed.length > 0;
  const tests = file.tests || [];
  const units = [...tests.map((t) => ({ line: t.line, endLine: t.endLine })), ...(file.units || []).filter((u) => u.kind !== 'test')];
  const own = f.test ? tests.find((t) => t.line === f.test.line) : null;
  const unit = own || units.filter((u) => inRange(f.line, u)).sort((a, b) => (a.endLine - a.line) - (b.endLine - b.line))[0];
  if (unit) return changed.some((l) => inRange(l, unit));
  const describes = file.describes || [];
  const d = describes.filter((x) => inRange(f.line, x)).sort((a, b) => (a.endLine - a.line) - (b.endLine - b.line))[0];
  const free = (l) => !units.some((u) => inRange(l, u));
  if (d) {
    const inner = describes.filter((x) => x !== d && x.line >= d.line && x.endLine <= d.endLine);
    return changed.some((l) => inRange(l, d) && free(l) && !inner.some((x) => inRange(l, x)));
  }
  return changed.some((l) => free(l) && !describes.some((x) => inRange(l, x)));
}
