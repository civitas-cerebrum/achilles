// The baseline commands of achilles-spec-lint (test-baseline.md §Baseline and ratchet):
//
//   --init-baseline                 record tests/compliance-baseline.json from HEAD, pin the id pattern, install
//                                   the pre-commit check
//   --update-baseline               lower the recorded counts to what the content has (never raise them);
//     [--ruleset-upgrade]           and record the rules a newer ruleset added or promoted
//   --ratchet --base <ref> [--ci]   the change against the baseline at the merge-base: touched tests clean,
//                                   untouched counts not above the baseline, the change's copy of the baseline
//                                   only lowered; --ci also lists deleted test ids and waiver changes
//   --pre-commit                    the same on the index against HEAD's baseline; fails open when it cannot run
//   --install-hook                  install the pre-commit check alone (every other clone)
//
// Each returns { code, report } and prints through the given `out` / `err` writers.
import { createRequire } from 'node:module';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { lintProject, factoryRules, PACKAGE_ROOT, RULEBOOK, DEFAULT_FILE_BUDGET_MS } from './engine.mjs';
import { stagedChange, baseChange, ChangeError } from './touched.mjs';
import { idPattern } from './ids.mjs';
import { BASELINE_FILE, parseBaseline, serialize, recount, makeBaseline, remap, ratchet, checkCopy, updateBaseline, inferIdPattern } from './baseline.mjs';
import { CURRENT_RULESET } from './rulesets.mjs';
import { headCommit, baselineAt, baselineCommit, baselineInHistory, renamesSince, headView, indexView, contentKeyParts, prefixOf } from './views.mjs';
import { cacheKey, readCache, writeCache } from './cache.mjs';
import { installHook, HookError } from './hooks.mjs';
import { gitSync, catBlobs } from './git.mjs';

const require = createRequire(import.meta.url);
const { DEFAULT_ID_RE } = require('../../../claude-code/lib/test-id-scan.js');

export const ANCHOR = `${RULEBOOK}#baseline-and-ratchet`;
const ENGINE = JSON.parse(readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8')).version;

export class UsageError extends Error {}

const three = (tag, what, todo, why = ANCHOR) => `[${tag}] ${what}\n→ Do: ${todo}\n→ Why/how: ${why}`;

function lineOf(f) {
  const where = f.line ? `${f.file}:${f.line}` : f.file || 'project';
  const id = f.test && f.test.id ? ` ${f.test.id}` : '';
  return `[${f.rule}] ${where}${id}: ${f.message}\n→ Do: ${f.do}\n→ Why/how: ${f.why}`;
}

const cellName = (v) => `${v.file}${v.scope === 'test' ? ` test ${v.key}` : v.scope === 'describe' ? ` describe "${v.key}"` : v.scope === 'file scope' ? ' (file scope)' : ''}`;

function ratchetLine(v, where) {
  const what = v.scope === 'totals'
    ? `${v.rule}: ${v.now} in the suite, ${v.baseline} in the baseline ${where}`
    : `${cellName(v)} ${v.rule}: ${v.now} now, ${v.baseline} in the baseline ${where} (untouched code gained findings)`;
  return three('ratchet', what, `bring ${v.scope === 'totals' ? 'the suite' : 'it'} back to at most ${v.baseline}: a change to a support module, a fixture or the framework version can add findings to tests the change did not touch, so fix what raised it (or touch the test and clean it)`);
}

function copyLine(v, where) {
  const f = BASELINE_FILE;
  switch (v.kind) {
    case 'deleted': return three('baseline', `${f}: the change deletes the baseline ${where}`, `restore it (\`git checkout <base> -- ${f}\`): a baseline is never deleted; lower it with \`achilles-spec-lint --update-baseline\``);
    case 'invalid': return three('baseline', `${f}: ${v.detail}`, 'restore the file and change it only with `achilles-spec-lint --update-baseline`');
    case 'raised': return three('baseline', `${f}: ${cellName(v)} ${v.rule} is recorded as ${v.recorded}, above the ${v.baseline} in the baseline ${where}`, 'a baseline count only goes down: restore it, fix the findings, or run `achilles-spec-lint --update-baseline`');
    case 'lowered': return three('baseline', `${f}: ${cellName(v)} ${v.rule} is recorded as ${v.recorded}, but the code has ${v.content}`, 'counts are recomputed from the code: fix the findings first, then run `achilles-spec-lint --update-baseline`');
    case 'padded': return three('baseline', `${f}: ${cellName(v)} ${v.rule} is recorded as ${v.recorded}, but the code has ${v.content}`, 'a new baseline records exactly what the code has: write it with `achilles-spec-lint --init-baseline`');
    default: return three('baseline', `${f}: ${v.detail}`, 'restore the field: only `achilles-spec-lint --update-baseline` changes the baseline, and the id pattern is a rule input that needs the person\'s decision');
  }
}

/** Lints the whole suite of a view against a change, through the cache. */
function suiteLint(root, { view = null, change = null, baselineIdPattern, budgetMs = DEFAULT_FILE_BUDGET_MS, useCache = true }) {
  const parts = useCache ? (() => {
    try {
      return [ENGINE, CURRENT_RULESET, view ? view.from : 'the working tree', headCommit(root), change ? change.from : null, change ? [...change.files].map(([r, c]) => [r, c.status, c.lines ? [...c.lines] : null]) : null,
        baselineIdPattern === undefined ? '(file)' : baselineIdPattern, process.env.CIVITAS_TEST_ID_PATTERN || '', process.env.FACTORY_RULES || '', budgetMs, contentKeyParts(root)];
    } catch { return null; }
  })() : null;
  const key = parts ? cacheKey(parts) : null;
  if (key) {
    const hit = readCache(root, key);
    if (hit) return { report: hit, cache: 'hit' };
  }
  const report = lintProject({ root, budgetMs, change, suite: true, all: true, tracked: view ? view.tracked : null, contents: view ? view.contents : null, baselineIdPattern });
  if (key) writeCache(root, key, report);
  return { report, cache: key ? 'miss' : 'off' };
}

const readFile = (abs) => (existsSync(abs) ? readFileSync(abs, 'utf8') : null);
const lsIndex = (root, rel) => { try { return gitSync(root, ['ls-files', '--', rel]).trim() !== ''; } catch { return false; } };

// ── --init-baseline ───────────────────────────────────────────────────────

export function initBaseline(root, { out, err, budgetMs }) {
  const head = headCommit(root);
  if (!head) throw new UsageError('there is no commit yet: commit the suite first; the baseline is recorded from HEAD');
  if (existsSync(path.join(root, BASELINE_FILE)) || lsIndex(root, BASELINE_FILE)) throw new UsageError(`${BASELINE_FILE} exists already: a baseline is recorded once; lower it with --update-baseline`);
  if (baselineInHistory(root)) {
    const at = baselineCommit(root, 'HEAD');
    throw new UsageError(`${BASELINE_FILE} existed in an ancestor commit (${at.slice(0, 12)}; see \`git log --diff-filter=D -- ${BASELINE_FILE}\`): restore that baseline instead of recording a new one, which would forgive every finding it counted`);
  }
  const view = headView(root);
  const pinned = idPattern(root, factoryRules(root), process.env, null);
  let id;
  if (pinned.pinned) id = pinned.re.source;
  else {
    const first = suiteLint(root, { view, baselineIdPattern: null, budgetMs, useCache: false }).report;
    id = inferIdPattern(first.files.flatMap((f) => f.tests.map((t) => t.title)), DEFAULT_ID_RE);
  }
  const { report } = suiteLint(root, { view, baselineIdPattern: id, budgetMs, useCache: false });
  let hook;
  try { hook = installHook(root); } catch (e) { if (e instanceof HookError) throw new UsageError(`the pre-commit check could not be installed: ${e.message}`); throw e; }
  const counts = recount(report);
  const b = makeBaseline({ counts, engine: ENGINE, createdFrom: head, idPattern: id, hook: { mode: hook.mode, path: hook.path } });
  const abs = path.join(root, BASELINE_FILE);
  mkdirSync(path.dirname(abs), { recursive: true });
  writeFileSync(abs, serialize(b));
  const n = Object.values(counts.totals).reduce((a, x) => a + x, 0);
  const files = Object.keys(counts.files).length;
  const toCommit = [BASELINE_FILE, ...(hook.mode === 'githooks' ? ['.githooks/'] : [])];
  out(`spec-lint: recorded ${BASELINE_FILE} from HEAD ${head.slice(0, 12)}: ${n} blocking finding(s) in ${files} file(s) (ruleset ${CURRENT_RULESET}); id pattern ${id === 'house-default' ? 'the house default' : id}${pinned.pinned ? ` (from ${pinned.source})` : ''}; pre-commit check ${hook.mode} (${hook.path})`);
  for (const x of hook.notes) out(`  ${x}`);
  out(`Commit these alone as \`chore(test): compliance baseline\`, then commit your change:\n  git add ${toCommit.join(' ')}${hook.mode === 'chained' || hook.mode === 'wrapped' || hook.mode === 'lefthook' ? ` ${hook.path}` : ''}\n  git commit -m "chore(test): compliance baseline"`);
  return { code: 0, report: { tool: 'achilles-spec-lint', mode: 'init-baseline', ok: true, baseline: BASELINE_FILE, createdFrom: head, idPattern: id, totals: counts.totals, files, hook } };
}

// ── --install-hook ────────────────────────────────────────────────────────

export function installHookCmd(root, { out }) {
  let hook;
  try { hook = installHook(root); } catch (e) { if (e instanceof HookError) throw new UsageError(e.message); throw e; }
  out(`spec-lint: pre-commit check ${hook.changed ? 'installed' : 'already installed'} (${hook.mode}: ${hook.path})`);
  for (const x of hook.notes) out(`  ${x}`);
  return { code: 0, report: { tool: 'achilles-spec-lint', mode: 'install-hook', ok: true, hook } };
}

// ── --update-baseline ─────────────────────────────────────────────────────

export function updateBaselineCmd(root, { out, err, upgrade, budgetMs }) {
  const text = readFile(path.join(root, BASELINE_FILE));
  if (text === null) throw new UsageError(`${BASELINE_FILE} does not exist: record one with --init-baseline`);
  const parsed = parseBaseline(text);
  if (parsed.problems) throw new UsageError(`${BASELINE_FILE} is not a valid baseline: ${parsed.problems.join('; ')}`);
  const renames = renamesSince(root, baselineCommit(root, 'HEAD'));
  const ref = remap(parsed.baseline, renames);
  const { report, cache } = suiteLint(root, { baselineIdPattern: ref.idPattern, budgetMs });
  const content = recount(report);
  const { next, lowered, increases } = updateBaseline(ref, content, { upgrade, engine: ENGINE });
  const after = serialize(next);
  const changed = after !== text;
  if (changed) writeFileSync(path.join(root, BASELINE_FILE), after);
  for (const v of increases) err(ratchetLine(v, 'file'));
  const moved = [...renames].filter(([a]) => parsed.baseline.files[a]).length;
  out(`spec-lint: ${changed ? 'updated' : 'left'} ${BASELINE_FILE}: ${lowered.length} count(s) lowered${moved ? `, ${moved} renamed file(s) carried` : ''}${upgrade ? `, ruleset ${next.ruleset}` : ''}${increases.length ? `; ${increases.length} count(s) above the baseline were not raised` : ''}; cache ${cache}; ${report.timing.ms} ms`);
  return { code: increases.length ? 1 : 0, report: { tool: 'achilles-spec-lint', mode: 'update-baseline', ok: !increases.length, changed, lowered, increases, ruleset: next.ruleset } };
}

// ── --ratchet / --pre-commit ──────────────────────────────────────────────

function check(root, { change, view, refText, copyText, renames, where, budgetMs }) {
  const ref = refText === null ? null : parseBaseline(refText);
  if (ref && ref.problems) throw new UsageError(`the baseline ${where} is not valid: ${ref.problems.join('; ')}`);
  const parsedCopy = copyText === null ? null : parseBaseline(copyText);
  // the change's copy follows the same renames: a file moved without an update keeps its entry
  const copy = parsedCopy && parsedCopy.baseline ? { baseline: remap(parsedCopy.baseline, renames) } : parsedCopy;
  const refB = ref ? remap(ref.baseline, renames) : null;
  const opted = !!(refB || copy);
  const pattern = refB ? refB.idPattern : copy && copy.baseline ? copy.baseline.idPattern : undefined;
  const { report, cache } = suiteLint(root, { view, change, baselineIdPattern: opted ? pattern : undefined, budgetMs });
  const touched = report.findings.filter((f) => f.severity === 'blocking' && !f.waived && f.touched !== false);
  const r = refB ? ratchet(refB, recount(report, { filter: (f) => f.touched === false })) : { violations: [], notes: [] };
  const copyProblems = opted ? checkCopy(refB, copy, recount(report)) : [];
  return { report, cache, touched, ratchet: r, copyProblems, opted, ref: refB };
}

function printCheck(res, { out, err, mode, where }) {
  for (const f of res.touched) err(lineOf(f));
  for (const v of res.ratchet.violations) err(ratchetLine(v, where));
  for (const v of res.copyProblems) err(copyLine(v, where));
  for (const n of res.ratchet.notes) err(`[ratchet] note: ${n}`);
  const s = res.report.summary;
  out(`spec-lint: ${mode}: ${s.files} file(s), ${res.touched.length} blocking in touched code, ${s.legacy ?? 0} legacy; ${res.opted ? `${res.ratchet.violations.length} ratchet violation(s), ${res.copyProblems.length} baseline-file problem(s) against the baseline ${where}` : 'no compliance baseline (the ratchet starts with `achilles-spec-lint --init-baseline`)'}; cache ${res.cache}${res.cache === "hit" ? "" : `; ${res.report.timing.ms} ms`}`);
}

const okOf = (res) => !res.touched.length && !res.ratchet.violations.length && !res.copyProblems.length;

const jsonOf = (res, mode, extra = {}) => ({
  tool: 'achilles-spec-lint', mode, ok: okOf(res), baseline: res.opted ? { ruleset: res.ref ? res.ref.ruleset : null, violations: res.ratchet.violations, problems: res.copyProblems, notes: res.ratchet.notes } : null,
  cache: res.cache, lint: res.report, ...extra,
});

export function ratchetCmd(root, { out, err, base, ci, budgetMs }) {
  const change = baseChange(root, base);
  const mb = change.base;
  const where = `at the merge-base ${mb.slice(0, 12)}`;
  const res = check(root, {
    change, view: null, refText: baselineAt(root, mb), copyText: readFile(path.join(root, BASELINE_FILE)),
    renames: renamesSince(root, baselineCommit(root, mb)), where, budgetMs,
  });
  printCheck(res, { out, err, mode: ci ? 'ci' : 'ratchet', where });
  let extra = {};
  if (ci) {
    const d = ciDeltas(root, change, res, budgetMs);
    for (const t of d.deletedTests) err(`[ci] deleted test: ${t}`);
    for (const w of d.waiverDeltas) err(`[ci] waivers: ${w.file} ${w.rule} ${w.before} → ${w.after}`);
    out(`spec-lint: ci: ${d.deletedTests.length} deleted test(s), ${d.waiverDeltas.length} waiver change(s)`);
    extra = d;
  }
  return { code: okOf(res) ? 0 : 1, report: jsonOf(res, ci ? 'ci' : 'ratchet', extra) };
}

/** --ci: the tests the change deletes (ids, else file and title) and the waived findings per file and rule before and after. */
function ciDeltas(root, change, res, budgetMs) {
  const mb = change.base;
  const back = new Map([...renamesSince(root, mb)].map(([a, b]) => [b, a]));
  const old = [...change.files].filter(([, c]) => c.status !== 'A').map(([rel]) => ({ rel, was: back.get(rel) || rel }));
  if (!old.length) return { deletedTests: [], waiverDeltas: [] };
  const prefix = prefixOf(root);
  const blobs = catBlobs(root, old.map((o) => `${mb}:${prefix}${o.was}`));
  const contents = new Map(old.map((o) => [o.was, blobs.get(`${mb}:${prefix}${o.was}`)]).filter(([, t]) => typeof t === 'string'));
  if (!contents.size) return { deletedTests: [], waiverDeltas: [] };
  const then = lintProject({ root, paths: [...contents.keys()], contents, budgetMs, baselineIdPattern: res.ref ? res.ref.idPattern : undefined });
  const forward = new Map(old.map((o) => [o.was, o.rel]));
  const key = (rel, t) => t.id || `${rel} › ${t.title}`;
  const now = new Set([...res.report.facts].flatMap(([rel, f]) => f.tests.map((t) => key(rel, t))));
  const deletedTests = [...new Set(then.files.flatMap((f) => f.tests.map((t) => key(forward.get(f.path) || f.path, t))))].filter((k) => !now.has(k)).sort();
  const count = (findings, map) => { const m = new Map(); for (const f of findings) if (f.waived) { const k = `${map(f.file)}\0${f.rule}`; m.set(k, (m.get(k) || 0) + 1); } return m; };
  const before = count(then.findings, (p) => forward.get(p) || p);
  const rels = new Set(old.map((o) => o.rel));
  const after = count(res.report.findings.filter((f) => rels.has(f.file)), (p) => p);
  const waiverDeltas = [...new Set([...before.keys(), ...after.keys()])].sort().map((k) => { const [file, rule] = k.split('\0'); return { file, rule, before: before.get(k) || 0, after: after.get(k) || 0 }; }).filter((w) => w.before !== w.after);
  return { deletedTests, waiverDeltas };
}

export function preCommit(root, { out, err, budgetMs }) {
  try {
    const change = stagedChange(root);
    const head = headCommit(root);
    const res = check(root, {
      change, view: indexView(root), refText: head ? baselineAt(root, 'HEAD') : null, copyText: baselineAt(root, ''),
      renames: head ? renamesSince(root, baselineCommit(root, 'HEAD'), { cached: true }) : new Map(), where: 'at HEAD', budgetMs,
    });
    printCheck(res, { out, err, mode: 'pre-commit', where: 'at HEAD' });
    return { code: okOf(res) ? 0 : 1, report: jsonOf(res, 'pre-commit') };
  } catch (e) {
    err(`achilles-pre-commit: warning: the test-baseline check could not run (${String(e && e.message ? e.message : e).split('\n')[0].slice(0, 300)}). The commit goes ahead; CI still checks it.\n→ Why/how: ${ANCHOR}`);
    return { code: 0, report: { tool: 'achilles-spec-lint', mode: 'pre-commit', ok: true, ranAs: 'fail-open', why: String(e && e.message ? e.message : e).split('\n')[0] } };
  }
}

export { ChangeError };
