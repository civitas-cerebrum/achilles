// Shared helpers of the spec-lint tests: build a throwaway project from a fixture and read its markers.
//
// A file fixture is one file with a header:
//   // spec-lint fixture: <what it shows>
//   // place: tests/e2e/flows/cart.ts     where it goes in the project (default tests/e2e/<file name>)
//   // pin: 0.3.5                         the framework version the project pins (default 0.3.12)
//   // rules: TB-A1 TB-A5                 the rules compared (default: the fixture directory's rule id)
//   // expect-project: TB-A13             project-level findings expected
//   // expect-file: TB-G0                 a finding anywhere in the file (line not compared)
// and markers on lines: `// EXPECT TB-A1 TB-A5/advisory TB-A2/waived` (this line), `// EXPECT-NEXT …`
// (the next line), `<!-- EXPECT … -->` in Markdown. A directory fixture holds a project tree plus
// fixture.json ({ rules, pin, project }). Projects are written outside any git checkout, so the surface
// chain falls through to the shipped snapshot for the pinned version.
//
// Code fixtures are stored with a `.txt` suffix (`bad-1-goto.spec.ts.txt`) so no TypeScript tooling run
// over this repository (the plugin validator's type check) loads them; materialise() drops the suffix.
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const FIXTURES = path.join(REPO, 'tests', 'bin', 'fixtures', 'spec-lint');

/** Copies a fixture tree into `root`, dropping the `.txt` suffix of stored code files. */
export function materialise(src, root) {
  for (const f of walk(src)) {
    const to = path.join(root, f.replace(/\.txt$/, ''));
    mkdirSync(path.dirname(to), { recursive: true });
    cpSync(path.join(src, f), to);
  }
  return root;
}

export function tempRoot() {
  return realpathSync(mkdtempSync(path.join(os.tmpdir(), 'spec-lint-')));
}

export function writeProject(root, files, { pin = '0.3.12' } = {}) {
  if (!('package.json' in files)) files = { 'package.json': JSON.stringify({ name: 'p', private: true, dependencies: { '@civitas-cerebrum/element-interactions': pin } }), ...files };
  for (const [rel, text] of Object.entries(files)) {
    const p = path.join(root, rel);
    mkdirSync(path.dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
  return root;
}

const header = (text, key) => {
  const m = new RegExp(`^//\\s*${key}:\\s*(.+)$`, 'm').exec(text);
  return m ? m[1].trim() : null;
};

/** Markers of one file: [{ rule, line, status }] where status is blocking | advisory | waived | undefined. */
export function markers(text, rel) {
  const out = [];
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    for (const re of [/EXPECT-NEXT((?:\s+TB-[A-Za-z0-9]+(?:\/\w+)?)+)/, /EXPECT((?:\s+TB-[A-Za-z0-9]+(?:\/\w+)?)+)/]) {
      const m = re.exec(l);
      if (!m) continue;
      const line = re.source.startsWith('EXPECT-NEXT') ? i + 2 : i + 1;
      for (const tok of m[1].trim().split(/\s+/)) {
        const [rule, status] = tok.split('/');
        out.push({ file: rel, rule, line, status });
      }
      break;
    }
  });
  return out;
}

const walk = (dir, base = dir) => readdirSync(dir).flatMap((f) => {
  const p = path.join(dir, f);
  return statSync(p).isDirectory() ? walk(p, base) : [path.relative(base, p).split(path.sep).join('/')];
});

/** Loads a fixture (file or directory) into a fresh project. */
export function loadFixture(fixturePath, defaultRule) {
  const root = tempRoot();
  if (statSync(fixturePath).isDirectory()) {
    const meta = JSON.parse(readFileSync(path.join(fixturePath, 'fixture.json'), 'utf8'));
    materialise(fixturePath, root);
    rmSync(path.join(root, 'fixture.json'));
    writeProject(root, {}, { pin: meta.pin || '0.3.12' });
    const files = walk(root).filter((f) => f !== 'package.json');
    const expected = files.flatMap((f) => markers(readFileSync(path.join(root, f), 'utf8'), f));
    return { root, rules: meta.rules || [defaultRule], expected, project: meta.project || [], fileLevel: [], cleanup: () => rmSync(root, { recursive: true, force: true }) };
  }
  const text = readFileSync(fixturePath, 'utf8');
  const place = header(text, 'place') || `tests/e2e/${path.basename(fixturePath).replace(/\.txt$/, '')}`;
  writeProject(root, { [place]: text }, { pin: header(text, 'pin') || '0.3.12' });
  const rules = (header(text, 'rules') || defaultRule).split(/\s+/);
  const project = (header(text, 'expect-project') || '').split(/\s+/).filter(Boolean);
  const fileLevel = (header(text, 'expect-file') || '').split(/\s+/).filter(Boolean).map((rule) => ({ file: place, rule }));
  return { root, rules, expected: markers(text, place), project, fileLevel, place, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

const key = (f) => `${f.file}:${f.line} ${f.rule}${f.status ? `/${f.status}` : ''}`;

/** Compares a report with a fixture's expectations; returns a list of mismatch lines (empty when equal). */
export function compare(report, fx) {
  const wanted = new Set(fx.rules);
  const fileLevelRules = new Set(fx.fileLevel.map((f) => `${f.file} ${f.rule}`));
  const actual = report.findings.filter((f) => wanted.has(f.rule) && !fileLevelRules.has(`${f.file} ${f.rule}`));
  const status = (f, want) => (f.waived ? 'waived' : want === undefined ? undefined : f.severity);
  const problems = [];
  const used = new Set();
  for (const e of fx.expected.filter((x) => wanted.has(x.rule))) {
    const i = actual.findIndex((f, j) => !used.has(j) && f.file === e.file && f.line === e.line && f.rule === e.rule && status(f, e.status) === e.status);
    if (i === -1) problems.push(`missing ${key(e)}`);
    else used.add(i);
  }
  actual.forEach((f, j) => { if (!used.has(j)) problems.push(`unexpected ${key({ ...f, status: f.waived ? 'waived' : f.severity })}: ${f.message}`); });
  for (const fl of fx.fileLevel) if (!report.findings.some((f) => f.file === fl.file && f.rule === fl.rule)) problems.push(`missing ${fl.rule} in ${fl.file}`);
  const proj = (report.project || []).filter((p) => wanted.has(p.rule)).map((p) => p.rule).sort();
  if (JSON.stringify(proj) !== JSON.stringify([...fx.project].sort())) problems.push(`project findings ${JSON.stringify(proj)}, expected ${JSON.stringify(fx.project)}`);
  return problems;
}
