import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { walk } from './util.mjs';

// Check 15 — the test baseline stays the one home of its rules.
//   a) test-baseline.md declares at least one rule and each id once; every rule
//      heading `#### TB-<id> …` is reachable at `#tb-<id>` (its heading slug, or an
//      explicit `<a id="tb-<id>">`); every cited `test-baseline.md#<anchor>` (and
//      every in-file `](#<anchor>)`) exists; every bare `TB-<id>` under skills/, docs/ and in CHANGELOG.md is a rule;
//   b) the first sentence of each rule (its normative sentence, at least six
//      words) appears in no other file under skills/, compared after
//      normalising case, punctuation, backticks and whitespace;
//   c) every rule whose Kind is mechanical (in whole or in part) has an engine
//      rule in achilles-spec-lint (bin/lib/spec-lint/rules/*.mjs) and a fixture
//      directory tests/bin/fixtures/spec-lint/<id>/, except the DEFERRED ones;
//      every engine rule is a rule of the rulebook.
export const BASELINE = 'skills/achilles-orchestrator/references/test-baseline.md';
const MIN_WORDS = 6;
const RULE_HEADING = /^#{2,6}\s+TB-([A-Z]\d+[a-z]?)\b/;
// `test-baseline.md#tb-<id>` (a placeholder) is not a citation.
const CITATION = /test-baseline\.md#([A-Za-z0-9_-]+)(?![A-Za-z0-9_<-])/g;
const LOCAL_LINK = /\]\(#([A-Za-z0-9_-]+)\)/g;
// A bare rule id named under skills/, docs/ or in the changelog (`TB-<id>` and `TB-…` placeholders do not match).
const BARE_ID = /\bTB-([A-Z]\d+[a-z]?)\b/g;

export function normalise(text) {
  return String(text).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

// GitHub's heading slug: lower-case, punctuation except `-` and `_` removed, spaces to `-`.
export function slug(heading) {
  return heading.trim().toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/ /g, '-');
}

function stripFences(lines) {
  let fenced = false;
  return lines.map((line) => {
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; return ''; }
    return fenced ? '' : line;
  });
}

export function anchorsOf(text) {
  const out = new Set();
  for (const line of stripFences(String(text).split('\n'))) {
    for (const m of line.matchAll(/<a\s+(?:id|name)="([^"]+)"/g)) out.add(m[1]);
    const h = line.match(/^#{1,6}\s+(.*?)\s*$/);
    if (h) out.add(slug(h[1]));
  }
  return out;
}

// The first sentence of a paragraph: it ends at `.`, `!` or `?` followed by
// whitespace or the end, outside inline code.
function firstSentence(paragraph) {
  let code = false;
  for (let i = 0; i < paragraph.length; i++) {
    const c = paragraph[i];
    if (c === '`') code = !code;
    else if (!code && /[.!?]/.test(c) && (i + 1 === paragraph.length || /\s/.test(paragraph[i + 1]))) return paragraph.slice(0, i + 1);
  }
  return paragraph;
}

// Rule sections: { id, heading, line, normative } for every `TB-<id>` heading;
// the normative sentence is the first sentence of the first prose paragraph after it.
export function ruleSections(text) {
  const lines = stripFences(String(text).split('\n'));
  const rules = [];
  lines.forEach((line, i) => {
    const m = line.match(RULE_HEADING);
    if (!m) return;
    const para = [];
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j].trim();
      if (!para.length && (l === '' || /^<a\s/.test(l))) continue; // blank lines and anchors before the paragraph
      if (l === '' || /^(#{1,6}\s|[-*|>]|<a\s)/.test(l)) break;     // the paragraph ends; a list or heading is not prose
      para.push(l);
    }
    rules.push({ id: m[1], heading: line.replace(/^#+\s+/, ''), line: i + 1, normative: para.length ? firstSentence(para.join(' ')) : '' });
  });
  return rules;
}

const lineOf = (text, index) => text.slice(0, index).split('\n').length;

export function baselineFindings(root = '.') {
  const at = (p) => join(root, p);
  const rel = (p) => relative(root, p).split('\\').join('/');
  const findings = { rules: [], citations: [], restated: [] };
  if (!existsSync(at(BASELINE))) {
    findings.rules.push(`${BASELINE}: not found`);
    return findings;
  }
  const text = readFileSync(at(BASELINE), 'utf8');
  const anchors = anchorsOf(text);
  const rules = ruleSections(text);

  if (!rules.length) findings.rules.push(`${BASELINE}: no TB rules found (expected "#### TB-<id> <title>" headings)`);
  const counts = new Map();
  for (const r of rules) counts.set(r.id, (counts.get(r.id) ?? 0) + 1);
  for (const [id, n] of counts) if (n > 1) findings.rules.push(`${BASELINE}: TB-${id} is declared ${n} times; one rule, one heading`);
  const ids = new Set(counts.keys());

  for (const r of rules) {
    const want = `tb-${r.id.toLowerCase()}`;
    if (!anchors.has(want)) findings.rules.push(`${BASELINE}:${r.line}: TB-${r.id} is not reachable at #${want} (add <a id="${want}"></a> above the heading)`);
    const words = normalise(r.normative).split(' ').filter(Boolean).length;
    if (words < MIN_WORDS) findings.rules.push(`${BASELINE}:${r.line}: TB-${r.id} normative sentence has ${words} words; it needs at least six words to be checked for restatement`);
  }

  const sources = [
    ...walk(at('skills'), (p) => p.endsWith('.md')),
    ...walk(at('docs'), (p) => p.endsWith('.md')),
    ...walk(at('agents'), (p) => p.endsWith('.md')),
    ...walk(at('claude-code'), (p) => /\.(ts|tsx|js|mjs|md)$/.test(p) && !p.includes('node_modules')),
    ...walk(at('pi'), (p) => /\.(ts|js|mjs|md)$/.test(p) && !p.includes('node_modules')),
    ...['CONTRIBUTING.md', 'README.md', 'CHANGELOG.md'].map(at).filter(existsSync),
  ];
  for (const file of sources) {
    const body = readFileSync(file, 'utf8');
    const name = rel(file);
    for (const m of body.matchAll(CITATION)) {
      if (!anchors.has(m[1])) findings.citations.push(`${name}:${lineOf(body, m.index)}: test-baseline.md#${m[1]} does not exist`);
    }
    if (name === BASELINE) {
      for (const m of body.matchAll(LOCAL_LINK)) {
        if (!anchors.has(m[1])) findings.citations.push(`${name}:${lineOf(body, m.index)}: #${m[1]} does not exist`);
      }
    }
  }

  // Bare rule ids: skills/, docs/ and the changelog.
  if (ids.size) {
    const named = [...walk(at('skills'), () => true), ...walk(at('docs'), (p) => p.endsWith('.md')), ...['CHANGELOG.md'].map(at).filter(existsSync)];
    for (const file of named) {
      const body = readFileSync(file, 'utf8');
      for (const m of body.matchAll(BARE_ID)) {
        if (!ids.has(m[1])) findings.citations.push(`${rel(file)}:${lineOf(body, m.index)}: TB-${m[1]} is not a rule of test-baseline.md`);
      }
    }
  }

  const checked = rules.filter((r) => normalise(r.normative).split(' ').length >= MIN_WORDS);
  for (const file of walk(at('skills'), () => true)) {
    const name = rel(file);
    const body = readFileSync(file, 'utf8');
    if (name === BASELINE) continue;
    const flat = ` ${normalise(body)} `;
    for (const r of checked) {
      if (flat.includes(` ${normalise(r.normative)} `)) findings.restated.push(`${name}: restates the normative sentence of TB-${r.id}; cite test-baseline.md#tb-${r.id.toLowerCase()} instead`);
    }
  }
  return findings;
}

export const ENGINE_RULES_DIR = 'bin/lib/spec-lint/rules';
export const FIXTURES_DIR = 'tests/bin/fixtures/spec-lint';
// Mechanical rules the engine does not detect itself, and why.
export const DEFERRED = {
  'TB-G2': 'rule inputs are decided at the commit gate (a later unit); the engine lists the rule only to keep it unwaivable',
  'TB-P3': 'detected as TB-F1 on the platform branch',
};

/** Rule ids with their Kind text: [{ id, kind }]. */
export function ruleKinds(text) {
  const out = [];
  const lines = stripFences(String(text).split('\n'));
  let cur = null;
  for (const line of lines) {
    const h = line.match(RULE_HEADING);
    if (h) { cur = { id: `TB-${h[1]}`, kind: null }; out.push(cur); continue; }
    const k = cur && !cur.kind && /\*\*Kind\*\*\s+([^·\n]+)/.exec(line);
    if (k) cur.kind = k[1].trim();
  }
  return out;
}

/** Ids the engine's rule families declare (`id: 'TB-…'` in RULES), with `pending` entries apart. */
export function engineRuleIds(root = '.') {
  const dir = join(root, ENGINE_RULES_DIR);
  const ids = new Set();
  const pending = new Set();
  if (!existsSync(dir)) return { ids, pending };
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.mjs'))) {
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      const m = /^\s*\{\s*id:\s*'(TB-[A-Z]\d+[a-z]?)'/.exec(line);
      if (m) (/\bpending:/.test(line) ? pending : ids).add(m[1]);
    }
  }
  return { ids, pending };
}

export function engineCoverage(root = '.') {
  const at = (p) => join(root, p);
  const problems = [];
  if (!existsSync(at(BASELINE))) return problems;
  const rules = ruleKinds(readFileSync(at(BASELINE), 'utf8'));
  const known = new Set(rules.map((r) => r.id));
  const { ids, pending } = engineRuleIds(root);
  for (const r of rules) {
    if (!r.kind || !/mechanical/.test(r.kind) || DEFERRED[r.id]) continue;
    if (!ids.has(r.id)) problems.push(`${BASELINE}: ${r.id} is mechanical (${r.kind}) but no rule family under ${ENGINE_RULES_DIR}/ implements it`);
    const fx = at(join(FIXTURES_DIR, r.id));
    if (!existsSync(fx) || !statSync(fx).isDirectory() || !readdirSync(fx).length) problems.push(`${r.id} has no fixture directory ${FIXTURES_DIR}/${r.id}/`);
  }
  for (const id of [...ids, ...pending]) if (!known.has(id)) problems.push(`${ENGINE_RULES_DIR}: ${id} is not a rule of ${BASELINE}`);
  return problems;
}

export function run(report) {
  const f = baselineFindings('.');
  report(`test-baseline rules are reachable at #tb-<id> and their normative sentences are checkable`, f.rules.length === 0, f.rules);
  report('cited test-baseline.md anchors exist', f.citations.length === 0, f.citations);
  report('no file under skills/ restates a test-baseline normative sentence', f.restated.length === 0, f.restated);
  const cov = engineCoverage('.');
  report('every mechanical test-baseline rule has an achilles-spec-lint rule and fixtures', cov.length === 0, cov);
}
