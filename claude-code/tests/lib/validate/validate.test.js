// The validator the ledger and return-review hooks run as a child process, against the schema fixtures.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const script = path.join(__dirname, '../../../lib/validate.mjs');
const schemas = path.join(__dirname, '../../../../schemas');
const run = (schema, text) => JSON.parse(spawnSync(process.execPath, [script, schema], { input: text, encoding: 'utf8' }).stdout || '{}');

const cases = [];
for (const f of fs.readdirSync(path.join(schemas, 'onboarding-status.fixtures'))) {
  cases.push({ name: `onboarding-status ${f}`, schema: 'onboarding-status', text: fs.readFileSync(path.join(schemas, 'onboarding-status.fixtures', f), 'utf8'), ok: f.startsWith('valid') });
}
for (const f of fs.readdirSync(path.join(schemas, 'subagent-returns', 'fixtures'))) {
  const role = f.replace(/-(valid|invalid).*$/, '');
  cases.push({ name: `subagent-returns/${role} ${f}`, schema: `subagent-returns/${role}`, text: fs.readFileSync(path.join(schemas, 'subagent-returns', 'fixtures', f), 'utf8'), ok: /-valid/.test(f) });
}
cases.push({ name: 'a json fence inside a markdown report', schema: 'subagent-returns/handover', text: '# Report\n\n```json\n{"role":"author","status":"DONE","next-action":"review"}\n```\n', ok: true });
cases.push({ name: 'unparseable text', schema: 'onboarding-status', text: '{"unterminated":', ok: false });

let failed = 0;
for (const c of cases) {
  const r = run(c.schema, c.text);
  const pass = r.ok === c.ok;
  if (!pass) failed++;
  console[pass ? 'log' : 'error'](`  ${pass ? '✓' : '✗'} ${c.name}${pass ? '' : ` — got ${JSON.stringify(r)}`}`);
}
const unknown = spawnSync(process.execPath, [script, '../etc/passwd'], { input: '{}', encoding: 'utf8' });
if (unknown.status !== 2) { failed++; console.error('  ✗ an unknown schema name exits 2'); } else console.log('  ✓ an unknown schema name exits 2');
console.log(`\n${cases.length + 1 - failed}/${cases.length + 1} passed`);
process.exit(failed === 0 ? 0 : 1);
