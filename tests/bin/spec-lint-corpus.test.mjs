// The seeded mutation corpus (tests/bin/fixtures/spec-lint/corpus): every marked line of the rule families
// the engine implements matches. EXPECT lines must carry each listed finding; CLEAN lines carry none;
// CLEAN-BLOCKING lines carry no blocking finding of the listed ids.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { lintProject, implementedRules } from '../../bin/lib/spec-lint/engine.mjs';
import { FIXTURES, tempRoot } from './spec-lint-helpers.mjs';

const CORPUS = path.join(FIXTURES, 'corpus');
const walk = (dir) => readdirSync(dir).flatMap((f) => {
  const p = path.join(dir, f);
  return statSync(p).isDirectory() ? walk(p) : [p];
});

test('the seeded corpus: every marked line of the implemented families matches', () => {
  const root = tempRoot();
  try {
    cpSync(CORPUS, root, { recursive: true });
    const report = lintProject({ root });
    const implemented = new Set(implementedRules().map((r) => r.id));
    const at = new Map();
    for (const f of report.findings) {
      const k = `${f.file}:${f.line}`;
      if (!at.has(k)) at.set(k, []);
      at.get(k).push(f);
    }
    const problems = [];
    let checked = 0;
    for (const abs of walk(path.join(root, 'tests'))) {
      const rel = path.relative(root, abs).split(path.sep).join('/');
      readFileSync(abs, 'utf8').split('\n').forEach((line, i) => {
        const here = at.get(`${rel}:${i + 1}`) || [];
        const exp = /\/\/ EXPECT((?:\s+TB-[A-Za-z0-9]+)+)/.exec(line);
        if (exp) {
          for (const id of exp[1].trim().split(/\s+/).filter((x) => implemented.has(x))) {
            checked++;
            if (!here.some((f) => f.rule === id)) problems.push(`${rel}:${i + 1} expected ${id}; got ${here.map((f) => f.rule).join(', ') || 'nothing'}`);
          }
        }
        const cb = /\/\/ CLEAN-BLOCKING((?:\s+TB-[A-Za-z0-9]+)+)/.exec(line);
        if (cb) {
          checked++;
          const ids = new Set(cb[1].trim().split(/\s+/));
          const bad = here.filter((f) => ids.has(f.rule) && f.severity === 'blocking');
          if (bad.length) problems.push(`${rel}:${i + 1} must have no blocking ${[...ids].join(' ')}; got ${bad.map((f) => `${f.rule}: ${f.message}`).join('; ')}`);
        } else if (/\/\/ CLEAN\b/.test(line)) {
          checked++;
          if (here.length) problems.push(`${rel}:${i + 1} must be clean; got ${here.map((f) => `${f.rule}: ${f.message}`).join('; ')}`);
        }
      });
    }
    assert.deepEqual(problems, []);
    assert.ok(checked >= 70, `only ${checked} marked checks ran`);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
