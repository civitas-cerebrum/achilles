// The compliance baseline and its ratchet (test-baseline.md §Baseline and ratchet).
//
// `tests/compliance-baseline.json` (schemas/compliance-baseline.schema.json) records, per file, the blocking
// findings of the rules its ruleset counts, in three buckets: per test (its id, else `<title>#<n>`), per
// describe scope outside every test (the describe titles from the outermost, joined with ` > `) and the file
// scope; `counts` is their sum per rule and `totals` the sum over files. Every number here is recomputed from
// the suite's content, never trusted from the file:
//
//   ratchet     the untouched findings of the change, per file, rule and bucket, may not exceed the reference
//               baseline (the one at the merge-base, or at HEAD for a commit); touched findings are the lint's
//               business (only the touched test must be clean)
//   copy        the change's own copy of the file may only lower counts, never below what the content has
//               (a hand-lowered count fails), never above the reference (a raise fails), and may not be deleted
//   update      writes the lower of the reference and the content, per bucket; --ruleset-upgrade also records
//               the rules a newer ruleset added or promoted
//
// Renames are carried: a reference entry follows its file through the `git diff -M` pairs since the baseline
// was last written.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv/dist/2020.js';
import { RULESETS, CURRENT_RULESET, PER_CHANGE, promotedBetween } from './rulesets.mjs';

export { BASELINE_FILE } from './ids.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCHEMA = path.resolve(HERE, '..', '..', '..', 'schemas', 'compliance-baseline.schema.json');
const BUCKETS = ['tests', 'describes'];

let validator = null;
function schemaValidator() {
  if (validator) return validator;
  const ajv = new (Ajv.default || Ajv)({ strict: true, allErrors: true, allowUnionTypes: true, strictSchema: false });
  validator = ajv.compile(JSON.parse(readFileSync(SCHEMA, 'utf8')));
  return validator;
}

const counted = (id, rulesets) => new Set((rulesets.find((r) => r.id === id) || { blocking: [] }).blocking.filter((x) => !PER_CHANGE.has(x)));
const known = (id, rulesets) => rulesets.some((r) => r.id === id);
const order = (id, rulesets) => rulesets.findIndex((r) => r.id === id);

// ── reading and writing ───────────────────────────────────────────────────

/**
 * Parses and checks a baseline text: { baseline } or { problems } (does not parse, fails the schema, or its
 * counts do not add up to their buckets and totals).
 */
export function parseBaseline(text, { rulesets = RULESETS } = {}) {
  let doc;
  try { doc = JSON.parse(text); } catch (e) { return { problems: [`does not parse as JSON (${e.message})`] }; }
  const v = schemaValidator();
  if (!v(doc)) return { problems: v.errors.slice(0, 5).map((e) => `${e.instancePath || '/'} ${e.message}`) };
  const problems = [];
  if (!known(doc.ruleset, rulesets)) problems.push(`ruleset ${doc.ruleset} is not one this Achilles knows (${rulesets.map((r) => r.id).join(', ')}): upgrade Achilles`);
  const totals = {};
  for (const [rel, f] of Object.entries(doc.files)) {
    const sum = sumBuckets(f);
    if (!sameCounts(sum, f.counts)) problems.push(`${rel}: counts do not equal the sum of its tests, describes and file scope`);
    for (const [r, n] of Object.entries(f.counts)) totals[r] = (totals[r] || 0) + n;
  }
  if (!sameCounts(totals, doc.totals)) problems.push('totals do not equal the sum of the files');
  return problems.length ? { problems } : { baseline: doc };
}

function sumBuckets(f) {
  const out = {};
  const add = (c) => { for (const [r, n] of Object.entries(c)) out[r] = (out[r] || 0) + n; };
  for (const b of BUCKETS) for (const c of Object.values(f[b])) add(c);
  add(f.fileScope);
  return out;
}

const sameCounts = (a, b) => {
  const ka = Object.keys(a).filter((k) => a[k]);
  const kb = Object.keys(b).filter((k) => b[k]);
  return ka.length === kb.length && ka.every((k) => a[k] === b[k]);
};

const sortObj = (o, fn = (v) => v) => Object.fromEntries(Object.keys(o).sort().map((k) => [k, fn(o[k])]));

/** The file text of a baseline: keys sorted, two-space JSON, a trailing newline (diffs stay small). */
export function serialize(b) {
  const file = (f) => ({ counts: sortObj(f.counts), waived: sortObj(f.waived), tests: sortObj(f.tests, sortObj), describes: sortObj(f.describes, sortObj), fileScope: sortObj(f.fileScope) });
  const out = { version: 1, ruleset: b.ruleset, engine: b.engine, createdFrom: b.createdFrom, idPattern: b.idPattern, ...(b.hook ? { hook: b.hook } : {}), totals: sortObj(b.totals), files: sortObj(b.files, file) };
  return `${JSON.stringify(out, null, 2)}\n`;
}

// ── counting ──────────────────────────────────────────────────────────────

/** A test's bucket key: its id, else `<title>#<n>`, the n-th test of that title in its file. */
export function testKeys(tests) {
  const seen = new Map();
  return new Map(tests.map((t) => {
    if (t.id) return [t.line, t.id];
    const n = (seen.get(t.title) || 0) + 1;
    seen.set(t.title, n);
    return [t.line, `${t.title}#${n}`];
  }));
}

const describePath = (describes, line) => describes
  .filter((d) => line >= d.line && line <= d.endLine)
  .sort((a, b) => a.line - b.line || b.endLine - a.endLine)
  .map((d) => d.title || '(untitled)')
  .join(' > ');

const newFile = () => ({ counts: {}, waived: {}, tests: {}, describes: {}, fileScope: {} });
const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };

/**
 * Counts a lint report (lintProject with `facts`) into baseline shape: { files, totals }. Only blocking
 * findings of the rules `ruleset` counts; waived ones go to `waived`. `filter` picks the findings counted
 * (the ratchet counts the untouched ones).
 */
export function recount(report, { ruleset = CURRENT_RULESET, rulesets = RULESETS, filter = () => true } = {}) {
  const rules = counted(ruleset, rulesets);
  const facts = report.facts || new Map();
  const keys = new Map();
  const files = {};
  for (const f of report.findings) {
    if (!rules.has(f.rule) || f.severity !== 'blocking' || !f.file || !filter(f)) continue;
    const entry = (files[f.file] ||= newFile());
    if (f.waived) { bump(entry.waived, f.rule); continue; }
    bump(entry.counts, f.rule);
    const fact = facts.get(f.file) || { tests: [], describes: [] };
    if (!keys.has(f.file)) keys.set(f.file, testKeys(fact.tests));
    const key = f.test ? keys.get(f.file).get(f.test.line) || (f.test.id || `${f.test.title}#1`) : null;
    if (key) bump((entry.tests[key] ||= {}), f.rule);
    else {
      const d = describePath(fact.describes, f.line || 1);
      if (d) bump((entry.describes[d] ||= {}), f.rule);
      else bump(entry.fileScope, f.rule);
    }
  }
  for (const [rel, e] of Object.entries(files)) if (!Object.keys(e.counts).length && !Object.keys(e.waived).length) delete files[rel];
  return { files, totals: totalsOf(files) };
}

function totalsOf(files) {
  const t = {};
  for (const f of Object.values(files)) for (const [r, n] of Object.entries(f.counts)) bump(t, r, n);
  return t;
}

/** A baseline document from a recount. */
export function makeBaseline({ counts, ruleset = CURRENT_RULESET, engine, createdFrom, idPattern, hook }) {
  return { version: 1, ruleset, engine, createdFrom, idPattern, ...(hook ? { hook } : {}), totals: counts.totals, files: counts.files };
}

/** The baseline with its file entries moved along `renames` (old rel → new rel). */
export function remap(b, renames) {
  if (!b || !renames || !renames.size) return b;
  const files = {};
  for (const [rel, f] of Object.entries(b.files)) {
    const to = renames.get(rel) || rel;
    if (!files[to] || to === rel) files[to] = f;
  }
  return { ...b, files };
}

// ── comparing ─────────────────────────────────────────────────────────────

/** Every (file, scope, key, rule) → n of a counts object, scope one of test, describe, file scope. */
function cells(files, rules) {
  const out = new Map();
  for (const [rel, f] of Object.entries(files || {})) {
    const put = (scope, key, c) => { for (const [r, n] of Object.entries(c)) if (rules.has(r)) out.set(JSON.stringify([rel, scope, key, r]), n); };
    for (const [k, c] of Object.entries(f.tests)) put('test', k, c);
    for (const [k, c] of Object.entries(f.describes)) put('describe', k, c);
    put('file scope', '', f.fileScope);
  }
  return out;
}

const fileCounts = (files, rules) => {
  const out = new Map();
  for (const [rel, f] of Object.entries(files || {})) for (const [r, n] of Object.entries(f.counts)) if (rules.has(r)) out.set(JSON.stringify([rel, r]), n);
  return out;
};

/**
 * The ratchet: the untouched counts `now` against the reference baseline `ref` (already moved along renames).
 * A rule that a ruleset newer than the reference's added or promoted has no recorded count yet: it is compared
 * with `refContent`, the reference commit's own content counted by this engine, when that is given, and is not
 * compared otherwise. Returns { violations, notes }; each violation names file, scope, key, rule, the reference
 * count and the count now.
 */
export function ratchet(ref, now, { rulesets = RULESETS, current = CURRENT_RULESET, refContent = null } = {}) {
  const promoted = promotedBetween(ref.ruleset, current, rulesets);
  const recorded = new Set([...counted(ref.ruleset, rulesets)].filter((r) => !promoted.has(r)));
  const later = new Set([...promoted].filter((r) => counted(current, rulesets).has(r)));
  const notes = [];
  if (later.size && !refContent) notes.push(`the baseline was recorded under ruleset ${ref.ruleset}; ${[...later].sort().join(', ')} ${later.size === 1 ? 'is' : 'are'} not compared until \`achilles-spec-lint --update-baseline --ruleset-upgrade\` records ${later.size === 1 ? 'it' : 'them'} (ruleset ${current})`);
  else if (later.size) notes.push(`the baseline was recorded under ruleset ${ref.ruleset}; ${[...later].sort().join(', ')} ${later.size === 1 ? 'is' : 'are'} compared with the reference commit's own content until \`achilles-spec-lint --update-baseline --ruleset-upgrade\` records ${later.size === 1 ? 'it' : 'them'} (ruleset ${current})`);
  const violations = [];
  const compare = (refSide, rules) => {
    const was = cells(refSide.files, rules);
    const found = [];
    for (const [k, n] of cells(now.files, rules)) {
      const b = was.get(k) || 0;
      if (n > b) { const [file, scope, key, rule] = JSON.parse(k); found.push({ kind: 'increase', file, scope, key, rule, baseline: b, now: n }); }
    }
    // a file or the totals can rise while every bucket holds (findings moved between buckets)
    const hit = new Set(found.map((v) => JSON.stringify([v.file, v.rule])));
    const wasFile = fileCounts(refSide.files, rules);
    for (const [k, n] of fileCounts(now.files, rules)) {
      const b = wasFile.get(k) || 0;
      if (n > b && !hit.has(k)) { const [file, rule] = JSON.parse(k); found.push({ kind: 'increase', file, scope: 'file', key: '', rule, baseline: b, now: n }); hit.add(k); }
    }
    for (const r of rules) {
      const n = (now.totals || {})[r] || 0;
      const b = (refSide.totals || {})[r] || 0;
      if (n > b && !found.some((v) => v.rule === r)) found.push({ kind: 'increase', file: '', scope: 'totals', key: '', rule: r, baseline: b, now: n });
    }
    return found;
  };
  violations.push(...compare(ref, recorded));
  if (refContent && later.size) violations.push(...compare(refContent, later));
  return { violations, notes };
}

const sameBaseline = (a, b) => serialize(a) === serialize(b);

/**
 * The change's own copy of the baseline against the reference (`ref`, moved along renames; null when the change
 * creates the file) and the full count of the content (`content`). A rule the copy's newer ruleset added or
 * promoted may be recorded up to its count in the reference commit's own content (`refContent`, counted by this
 * engine), never above, so a regression written in the same change is not absorbed. Returns a list of violations.
 */
export function checkCopy(ref, copy, content, { rulesets = RULESETS, current = CURRENT_RULESET, refContent = null } = {}) {
  if (!copy && !ref) return [];
  if (!copy) return [{ kind: 'deleted' }];
  if (copy.problems) return copy.problems.map((p) => ({ kind: 'invalid', detail: p }));
  const c = copy.baseline;
  if (ref && sameBaseline(ref, c)) return [];
  const out = [];
  if (ref) {
    if (c.idPattern !== ref.idPattern) out.push({ kind: 'idPattern', detail: `idPattern changed from ${JSON.stringify(ref.idPattern)} to ${JSON.stringify(c.idPattern)}` });
    if (c.createdFrom !== ref.createdFrom) out.push({ kind: 'createdFrom', detail: `createdFrom changed from ${ref.createdFrom} to ${c.createdFrom}` });
    if (JSON.stringify(c.hook || null) !== JSON.stringify(ref.hook || null)) out.push({ kind: 'hook', detail: `the recorded pre-commit check changed from ${JSON.stringify(ref.hook || null)} to ${JSON.stringify(c.hook || null)}` });
    if (order(c.ruleset, rulesets) < order(ref.ruleset, rulesets)) out.push({ kind: 'ruleset', detail: `ruleset went back from ${ref.ruleset} to ${c.ruleset}` });
  } else if (c.ruleset !== current) out.push({ kind: 'ruleset', detail: `a new baseline is recorded under the current ruleset ${current}, not ${c.ruleset}` });
  const rules = counted(c.ruleset, rulesets);
  const upgraded = ref ? promotedBetween(ref.ruleset, c.ruleset, rulesets) : new Set();
  const was = ref ? cells(ref.files, rules) : null;
  const base = refContent ? cells(refContent.files, rules) : null;
  const is = cells(c.files, rules);
  const has = cells(content.files, rules);
  for (const k of new Set([...is.keys(), ...has.keys(), ...(was ? was.keys() : [])])) {
    const [file, scope, key, rule] = JSON.parse(k);
    const n = is.get(k) || 0;
    const r = has.get(k) || 0;
    const cell = { file, scope, key, rule, recorded: n, content: r };
    if (!ref) {
      if (n < r) out.push({ kind: 'lowered', ...cell });
      else if (n > r) out.push({ kind: 'padded', ...cell });
      continue;
    }
    const b = upgraded.has(rule) ? (base ? base.get(k) || 0 : 0) : was.get(k) || 0;
    if (n > b) out.push({ kind: 'raised', ...cell, baseline: b });
    else if (n < r) out.push({ kind: 'lowered', ...cell, baseline: b });
  }
  return out;
}

/**
 * `--update-baseline`: the lower of the reference and the content per bucket (`--ruleset-upgrade`: the rules
 * added or promoted since the reference's ruleset are recorded from the content and the ruleset moves to the
 * current one). Returns { next, lowered, increases } where `increases` are the counts the content has above
 * the reference (not written).
 */
export function updateBaseline(ref, content, { upgrade = false, engine, rulesets = RULESETS, current = CURRENT_RULESET } = {}) {
  const ruleset = upgrade ? current : ref.ruleset;
  const rules = counted(ruleset, rulesets);
  const upgraded = upgrade ? promotedBetween(ref.ruleset, current, rulesets) : new Set();
  const was = cells(ref.files, rules);
  const has = cells(content.files, rules);
  const files = {};
  const lowered = [];
  const increases = [];
  for (const k of new Set([...was.keys(), ...has.keys()])) {
    const [file, scope, key, rule] = JSON.parse(k);
    const b = was.get(k) || 0;
    const r = has.get(k) || 0;
    const v = upgraded.has(rule) ? r : Math.min(b, r);
    if (!upgraded.has(rule) && r > b) increases.push({ file, scope, key, rule, baseline: b, now: r });
    if (v < b) lowered.push({ file, scope, key, rule, baseline: b, now: v });
    if (!v) continue;
    const e = (files[file] ||= newFile());
    const target = scope === 'test' ? (e.tests[key] ||= {}) : scope === 'describe' ? (e.describes[key] ||= {}) : e.fileScope;
    target[rule] = v;
    bump(e.counts, rule, v);
  }
  for (const [rel, f] of Object.entries(content.files)) {
    const w = Object.fromEntries(Object.entries(f.waived).filter(([r]) => rules.has(r)));
    if (Object.keys(w).length) (files[rel] ||= newFile()).waived = w;
  }
  const next = { ...ref, ruleset, engine: engine || ref.engine, totals: totalsOf(files), files };
  return { next, lowered, increases };
}

// ── the id pattern an init pins ───────────────────────────────────────────

/** The share of titles one id shape must hold to be pinned; below it the suite has no consistent ids. */
export const ID_SHARE = 0.9;
const BOUNDARY = '(?=[\\s:·—|]|$)';
const DOCUMENTED = `^\\s*([A-Z]{2,5}-[0-9]{2,4})${BOUNDARY}`;
const LEAD = /^\s*[[(]?([^\s\])·:—|]+)/;
// the shapes an id takes: a single uppercase prefix, several uppercase segments, or a lowercase convention of
// any number of segments; each ends in a hyphen and a run of digits
const SHAPES = [
  { name: 'upper', re: /^([A-Z]+)-(\d+)$/ },
  { name: 'upper-multi', re: /^([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)+)-(\d+)$/ },
  { name: 'lower', re: /^([a-z][a-z0-9]*(?:-[a-z0-9]+)*)-(\d+)$/ },
];
const range = (xs, lo, hi) => `{${Math.min(lo, ...xs)},${Math.max(hi, ...xs)}}`;

/**
 * The id pattern the suite already uses, from its test titles: { pattern, matched, of }. One shape held by at
 * least ID_SHARE of the titles is pinned, widened for ordinary growth (a prefix of 2 to 5 letters, 2 to 4
 * digits, or wider when the ids are; a lowercase convention needs three distinct ids under one leading segment),
 * and the documented `^\s*([A-Z]{2,5}-[0-9]{2,4})` with its right boundary when every id fits it;
 * `house-default` when the house default holds that share, or when no shape does.
 */
export function inferIdPattern(titles, houseDefault) {
  const of = titles.length;
  const share = (n) => of > 0 && n / of >= ID_SHARE;
  const house = titles.filter((t) => houseDefault.test(t || '')).length;
  if (!of || share(house)) return { pattern: 'house-default', matched: house, of };
  let best = null;
  for (const shape of SHAPES) {
    let hits = titles.map((t) => LEAD.exec(t || '')).filter(Boolean).map((m) => shape.re.exec(m[1])).filter(Boolean);
    // a lowercase convention needs at least three distinct ids under one leading segment: ordinary hyphenated
    // words ending in digits (covid-19, top-10) are not ids
    if (shape.name === 'lower') {
      const groups = new Map();
      for (const h of hits) { const g = h[0].split('-')[0]; if (!groups.has(g)) groups.set(g, new Set()); groups.get(g).add(h[0]); }
      hits = hits.filter((h) => groups.get(h[0].split('-')[0]).size >= 3);
    }
    if (!best || hits.length > best.hits.length) best = { shape, hits };
  }
  if (!best || !share(best.hits.length)) return { pattern: 'house-default', matched: best ? best.hits.length : 0, of };
  const digits = best.hits.map((m) => m[2].length);
  const d = range(digits, 2, 4);
  let pattern;
  if (best.shape.name === 'upper') {
    const lens = best.hits.map((m) => m[1].length);
    const p = range(lens, 2, 5);
    pattern = p === '{2,5}' && d === '{2,4}' ? DOCUMENTED : `^\\s*([A-Z]${p}-[0-9]${d})${BOUNDARY}`;
  } else if (best.shape.name === 'upper-multi') pattern = `^\\s*[[(]?([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)+-[0-9]${d})[\\])]?(?=[\\s:·—|]|$)`;
  else pattern = `^\\s*[[(]?([a-z][a-z0-9]*(?:-[a-z0-9]+)*-[0-9]${d})[\\])]?(?=[\\s:·—|]|$)`;
  return { pattern, matched: best.hits.length, of };
}
