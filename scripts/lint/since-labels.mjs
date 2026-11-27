// Check 16: every "since" label of the Steps API reference names the release that first shipped its methods,
// read from the published surfaces the spec lint ships (bin/lib/spec-lint/surfaces/<version>.json, built from
// the published releases), never from an installed copy or the documentation itself.
//
// A since label is `<major>.<minor>.<patch>+`. Its methods:
//   - on a code line that calls Steps methods (`steps.<m>(`): the methods that line calls;
//   - on a comment line of a code block: the Steps methods the code lines after that comment call, up to the
//     next blank or comment line (continuation lines of the same comment are skipped first);
//   - on a heading: the Steps methods the section's code calls, up to the next heading of the same level or above;
//   - on a prose line: the Steps methods it names in backticks.
// The label must equal the newest first release among its methods (a block labelled 0.3.8 needs 0.3.8; an
// older method in the same block is fine), and a label must name at least one Steps method. Options, return
// types, fluent members and repository behaviours are not in the surfaces: their notes say "from <version>"
// and are checked against the published type definitions by hand when written.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const API_REFERENCE = 'skills/achilles-orchestrator/references/api-reference.md';
export const SURFACES = 'bin/lib/spec-lint/surfaces';
const LABEL = /\b(\d+\.\d+\.\d+)\+/g;
const CALL = /\bsteps\.([A-Za-z_$][\w$]*)\s*\(/g;
const TICK = /`([A-Za-z_$][\w$]*)(?:\([^`]*\))?`/g;

const cmp = (a, b) => { const x = a.split('.').map(Number); const y = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };

/** Method → the first published release whose Steps surface has it. */
export function firstReleases(root = '.') {
  const dir = join(root, SURFACES);
  if (!existsSync(dir)) return new Map();
  const versions = readdirSync(dir).filter((f) => /^\d+\.\d+\.\d+\.json$/.test(f)).map((f) => f.slice(0, -5)).sort(cmp);
  const first = new Map();
  for (const v of versions) {
    const s = JSON.parse(readFileSync(join(dir, `${v}.json`), 'utf8'));
    for (const m of [...(s.methods || []), ...(s.properties || [])]) if (!first.has(m)) first.set(m, v);
  }
  return first;
}

/** Every since label of `text` with the methods it labels: [{ line, label, methods }]. */
export function sinceLabels(text) {
  const lines = text.split('\n');
  const fence = [];
  let inCode = false;
  for (const l of lines) { if (/^\s*```/.test(l)) { fence.push(true); inCode = !inCode; } else fence.push(inCode); }
  const calls = (l) => [...l.replace(/\/\/.*$/, '').matchAll(CALL)].map((m) => m[1]);
  const isComment = (i) => fence[i] && /^\s*\/\//.test(lines[i]);
  const out = [];
  lines.forEach((l, i) => {
    const labels = [...l.matchAll(LABEL)].map((m) => m[1]);
    if (!labels.length) return;
    let methods;
    const heading = /^(#{1,6})\s/.exec(l);
    if (heading) {
      methods = [];
      let code = false;
      for (let j = i + 1; j < lines.length; j++) {
        const h = /^(#{1,6})\s/.exec(lines[j]);
        if (h && !code && h[1].length <= heading[1].length) break;
        if (/^\s*```/.test(lines[j])) code = !code;
        else if (code) methods.push(...calls(lines[j]));
      }
    } else if (isComment(i)) {
      methods = [];
      let j = i + 1;
      while (j < lines.length && isComment(j)) j++;
      for (; j < lines.length && fence[j] && !/^\s*```/.test(lines[j]) && lines[j].trim() && !isComment(j); j++) methods.push(...calls(lines[j]));
    } else if (fence[i]) methods = calls(l);
    else methods = [...l.matchAll(TICK)].map((m) => m[1]);
    for (const label of labels) out.push({ line: i + 1, label, methods: [...new Set(methods)] });
  });
  return out;
}

/** Problems: a label that names no Steps method, or that differs from the newest first release of its methods. */
export function sinceProblems(text, first, file = API_REFERENCE) {
  const problems = [];
  for (const { line, label, methods } of sinceLabels(text)) {
    const known = methods.filter((m) => first.has(m));
    if (!known.length) { problems.push(`${file}:${line}: the since label ${label}+ names no Steps method (an option, return type, fluent member or repository behaviour is written "from ${label}")`); continue; }
    const newest = known.reduce((a, m) => (cmp(first.get(m), first.get(a)) > 0 ? m : a));
    const want = first.get(newest);
    if (want !== label) problems.push(`${file}:${line}: labelled ${label}+, but the newest of its methods (${known.map((m) => `${m} ${first.get(m)}`).join(', ')}) first shipped in ${want}`);
  }
  return problems;
}

export function run(report) {
  if (!existsSync(API_REFERENCE)) { report(`${API_REFERENCE} exists`, false, [`${API_REFERENCE} is missing`]); return; }
  const first = firstReleases('.');
  const problems = first.size ? sinceProblems(readFileSync(API_REFERENCE, 'utf8'), first) : [`no shipped surfaces under ${SURFACES}`];
  report('every since label in the Steps API reference matches the published surfaces', problems.length === 0, problems);
}
