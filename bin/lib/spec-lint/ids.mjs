// The test-id pattern (test-baseline.md TB-I1): CIVITAS_TEST_ID_PATTERN, else the factory rules'
// specs.shape.titleIdPattern, else a compliance baseline's recorded `idPattern`, else the house default
// (unpinned). One pattern source with the adapter's test-id scan (claude-code/lib/test-id-scan.js).
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { DEFAULT_ID_RE } = require('../../../claude-code/lib/test-id-scan.js');

export const BASELINE_FILE = 'tests/compliance-baseline.json';
export const INDEX_FILE = 'tests/e2e/docs/test-ids.md';

const compile = (src) => { try { return new RegExp(src); } catch { return null; } };

/** `.env` value of a key (KEY=value, optional quotes), or undefined. */
function envFileValue(root, key) {
  const p = path.join(root, '.env');
  if (!existsSync(p)) return undefined;
  for (const line of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = new RegExp(`^\\s*(?:export\\s+)?${key}\\s*=\\s*(.*?)\\s*$`).exec(line);
    if (m) return m[1].replace(/^(['"])(.*)\1$/, '$2');
  }
  return undefined;
}

/**
 * The project's id pattern: { re, pinned, source, text }. `re` matches at the start of a title with the id in
 * group 1 (or the whole match). An unparseable pinned value is reported and the house default applies.
 * `recorded` stands in for the baseline file's `idPattern` (the baseline a ratchet compares against, or the
 * pattern an init is about to record); undefined reads the file on disk.
 */
export function idPattern(root, factory, env = process.env, recorded = undefined) {
  const fromEnv = env.CIVITAS_TEST_ID_PATTERN || envFileValue(root, 'CIVITAS_TEST_ID_PATTERN');
  const problems = [];
  if (fromEnv) {
    const re = compile(fromEnv);
    if (re) return { re, pinned: true, source: 'CIVITAS_TEST_ID_PATTERN', text: fromEnv, problems };
    problems.push(`CIVITAS_TEST_ID_PATTERN (${fromEnv}) is not a valid regular expression`);
  }
  const shape = factory?.rules?.['specs.shape']?.titleIdPattern;
  if (typeof shape === 'string' && shape) {
    // written for scenario headings (`^LGN-\d{2} — `): the id core, then any of the separators a title may use
    const core = shape.replace(/^\^/, '').replace(/\s*(?:—|·|-|:)\s*$/, '');
    const re = compile(`^\\s*[[(]?(${core})[\\])]?(?=[\\s:·—|-]|$)`);
    if (re) return { re, pinned: true, source: 'specs.shape.titleIdPattern', text: shape, problems };
    problems.push(`specs.shape.titleIdPattern (${shape}) is not a valid regular expression`);
  }
  const bl = path.join(root, BASELINE_FILE);
  if (recorded !== undefined || existsSync(bl)) {
    let rec = recorded === undefined ? null : recorded;
    if (recorded === undefined) try { rec = JSON.parse(readFileSync(bl, 'utf8')).idPattern; } catch { problems.push(`${BASELINE_FILE} does not parse`); }
    if (rec === 'house-default') return { re: DEFAULT_ID_RE, pinned: true, source: `${BASELINE_FILE} idPattern`, text: 'house-default', problems };
    if (typeof rec === 'string' && rec) {
      const re = compile(rec);
      if (re) return { re, pinned: true, source: `${BASELINE_FILE} idPattern`, text: rec, problems };
      problems.push(`${BASELINE_FILE} idPattern (${rec}) is not a valid regular expression`);
    }
  }
  return { re: DEFAULT_ID_RE, pinned: false, source: 'house default', text: DEFAULT_ID_RE.source, problems };
}

/** The id at the start of `title` under `pattern`, with what follows it: { id, rest } or null. */
export function idOf(title, pattern) {
  const m = pattern.re.exec(title || '');
  if (!m) return null;
  return { id: (m[1] || m[0]).trim(), rest: title.slice(m.index + m[0].length) };
}

/** Every id-shaped token in `title` under the pattern (to count titles with two ids). */
export function idsIn(title, pattern) {
  const core = pattern.re.source.replace(/^\^\\s\*/, '').replace(/^\^/, '');
  let re;
  try { re = new RegExp(core.replace(/\(\?=[^)]*\)$/, ''), 'g'); } catch { return []; }
  return [...String(title || '').matchAll(re)].map((m) => (m[1] || m[0]).trim()).filter(Boolean);
}
