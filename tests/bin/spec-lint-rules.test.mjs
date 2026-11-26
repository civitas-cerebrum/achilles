// Per-rule fixtures of achilles-spec-lint: every fixture under tests/bin/fixtures/spec-lint/<rule-id>/ and
// bindings/ produces exactly the findings its markers name (see spec-lint-helpers.mjs for the grammar).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { FIXTURES, loadFixture, compare } from './spec-lint-helpers.mjs';

const dirs = readdirSync(FIXTURES).filter((d) => /^TB-|^bindings$/.test(d) && statSync(path.join(FIXTURES, d)).isDirectory()).sort();

// The mechanical rules of this engine: each needs at least two compliant and two non-compliant fixtures.
const MECHANICAL = ['TB-A1', 'TB-A2', 'TB-A2b', 'TB-A3', 'TB-A4', 'TB-A5', 'TB-A7', 'TB-A9', 'TB-A10', 'TB-A11', 'TB-A12', 'TB-A13', 'TB-A14', 'TB-G0', 'TB-G1'];

test('no fixture is stored with a code extension (TypeScript tooling over the repository must not load them)', () => {
  const walk = (d) => readdirSync(d).flatMap((f) => (statSync(path.join(d, f)).isDirectory() ? walk(path.join(d, f)) : [path.join(d, f)]));
  assert.deepEqual(walk(FIXTURES).filter((f) => /\.(?:[cm]?[jt]sx?)$/.test(f)).map((f) => path.relative(FIXTURES, f)), []);
});

test('every mechanical rule has at least two compliant and two non-compliant fixtures', () => {
  for (const rule of MECHANICAL) {
    assert.ok(dirs.includes(rule), `fixture directory ${rule} missing`);
    const names = readdirSync(path.join(FIXTURES, rule));
    assert.ok(names.filter((n) => n.startsWith('ok-')).length >= 2, `${rule}: fewer than two compliant fixtures`);
    assert.ok(names.filter((n) => n.startsWith('bad-')).length >= 2, `${rule}: fewer than two non-compliant fixtures`);
  }
});

for (const dir of dirs) {
  for (const name of readdirSync(path.join(FIXTURES, dir)).filter((n) => /^(ok|bad)-/.test(n)).sort()) {
    test(`${dir}/${name}`, () => {
      const fx = loadFixture(path.join(FIXTURES, dir, name), dir);
      try {
        const report = lintProject({ root: fx.root });
        assert.deepEqual(compare(report, fx), []);
        if (name.startsWith('ok-')) {
          const blocking = report.findings.filter((f) => fx.rules.includes(f.rule) && f.severity === 'blocking' && !f.waived);
          assert.deepEqual(blocking.map((f) => `${f.rule} ${f.file}:${f.line}`), [], 'a compliant fixture has no unwaived blocking finding of its rules');
        }
      } finally { fx.cleanup(); }
    });
  }
}
