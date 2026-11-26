// Defect pointers and sentinels (test-baseline.md §Defect pointers and sentinels).
//
//   // defect: <ref>     in the test's (or describe's) own contiguous comment block, directly above the call
//
// <ref> is a repo-relative path with an optional #anchor that exists (GitHub heading slugs or explicit
// <a id>), a tracker key <KEY>-<n> (shape only), or a defect id <TICKET>-D<n> resolved against
// .achilles/defect-confirmations/<TICKET>/<id>.json where that directory exists (shape only elsewhere).
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { blockAbove } from './waivers.mjs';

const POINTER = /^\s*\/\/\s*defect:\s*(\S+)/;
const TRACKER = /^[A-Z][A-Z0-9_]*-\d+$/;
const DEFECT_ID = /^([A-Z][A-Z0-9_]*-\d+)-D\d+$/;
export const CONFIRMATIONS = '.achilles/defect-confirmations';
/** `[SENTINEL <TICKET>-D<n>]` in a verify-change sentinel title. */
export const SENTINEL_TITLE = /\[SENTINEL ([A-Z][A-Z0-9_]*-\d+-D\d+)\]/;

/** GitHub's heading slug: lower-case, punctuation except `-` and `_` removed, spaces to `-`. */
export const slug = (h) => h.trim().toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/ /g, '-');

const anchorCache = new Map();
function anchorsOf(abs) {
  if (anchorCache.has(abs)) return anchorCache.get(abs);
  const out = new Set();
  let fenced = false;
  for (const line of readFileSync(abs, 'utf8').split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
    if (fenced) continue;
    for (const m of line.matchAll(/<a\s+(?:id|name)="([^"]+)"/g)) out.add(m[1]);
    const h = /^#{1,6}\s+(.*?)\s*#*\s*$/.exec(line);
    if (h) {
      const s = slug(h[1]);
      // GitHub numbers repeated slugs: the second `## Notes` is #notes-1
      let k = s, i = 1;
      while (out.has(k)) k = `${s}-${i++}`;
      out.add(k);
    }
  }
  anchorCache.set(abs, out);
  return out;
}

/** The `// defect:` refs in the contiguous comment block directly above `line`: [{ ref, line }]. */
export function pointersAbove(file, line) {
  return blockAbove(line, file.commentLines).map((l) => ({ m: POINTER.exec(file.lines[l - 1]), line: l })).filter((x) => x.m).map((x) => ({ ref: x.m[1], line: x.line }));
}

/** Resolves a ref: { ok, kind, key, problem }. `key` is what the ref names (anchor, tracker key or defect id). */
export function resolveRef(root, ref) {
  if (DEFECT_ID.test(ref)) {
    const dir = path.join(root, CONFIRMATIONS);
    if (!existsSync(dir)) return { ok: true, kind: 'defect-id', key: ref };
    const ticket = DEFECT_ID.exec(ref)[1];
    return existsSync(path.join(dir, ticket, `${ref}.json`)) ? { ok: true, kind: 'defect-id', key: ref } : { ok: false, kind: 'defect-id', key: ref, problem: `${ref} has no record under ${CONFIRMATIONS}/${ticket}/` };
  }
  if (TRACKER.test(ref)) return { ok: true, kind: 'tracker', key: ref };
  const [p, anchor] = ref.split('#');
  if (!p || /^[a-z]+:\/\//i.test(ref) || (!p.includes('/') && !p.includes('.'))) return { ok: false, kind: 'unknown', key: ref, problem: `"${ref}" is not a repo-relative path, a tracker key <KEY>-<n> or a defect id <TICKET>-D<n>` };
  const abs = path.resolve(root, p);
  if (!abs.startsWith(path.resolve(root)) || !existsSync(abs) || !statSync(abs).isFile()) return { ok: false, kind: 'path', key: ref, problem: `${p} does not exist in the repository` };
  if (anchor === undefined || anchor === '') return { ok: true, kind: 'path', key: p };
  return anchorsOf(abs).has(anchor) ? { ok: true, kind: 'path', key: anchor } : { ok: false, kind: 'path', key: anchor, problem: `${p} has no heading or <a id> for #${anchor}` };
}

/** True when a resolved ref names register key `key` (`L3` ↔ `#l3`, `#l3-…`; a tracker key or defect id equal to it). */
export function refNames(resolved, key) {
  if (!resolved.ok) return false;
  const k = key.toLowerCase();
  const r = String(resolved.key).toLowerCase();
  return r === k || r.startsWith(`${slug(key)}-`) || r === slug(key);
}
