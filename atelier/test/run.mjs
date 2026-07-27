#!/usr/bin/env node
// Standalone test suite for harness-atelier.mjs — zero dependencies, plain
// node:assert. Mirrors the surface the Achilles-side integration case
// (hooks/tests/cases/73-harness-atelier-cli.sh) covers, so this directory
// stays fully testable after being severed into its own repository.
//
// Run: npm test   (or: node test/run.mjs)

import { strict as assert } from 'node:assert';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'harness-atelier.mjs');

const FIXTURE = `
{"ts":"2026-07-26T09:58:00Z","event":"skill","actor":"orchestrator","role":"orchestrator","skill":"coverage-expansion","bytes_in":40,"bytes_out":5000}
{"ts":"2026-07-26T10:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","brief_bytes":4000,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:05:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","return_bytes":900,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:06:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","brief_bytes":3000,"description":"probe-j-checkout-4: adversarial probe"}
{"ts":"2026-07-26T10:12:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","return_bytes":9500,"description":"probe-j-checkout-4: adversarial probe","leak":{"channel":"oversized-return","evidence":"return is 9500 bytes (budget 8000)"}}
{"ts":"2026-07-26T10:13:00Z","event":"command","actor":"orchestrator","role":"orchestrator","tool":"Bash","bytes_out":2048,"command_head":"cat tests/e2e/journeys/checkout.spec.ts","leak":{"channel":"bash-ingest","evidence":"payload dump executed in orchestrator context: cat tests/e2e/journeys/checkout.spec.ts"}}
{"ts":"2026-07-26T10:14:00Z","event":"command","actor":"sub_c1","role":"composer","tool":"Bash","bytes_out":512,"command_head":"npx playwright test"}
{"ts":"2026-07-26T10:15:00Z","event":"tool","actor":"orchestrator","role":"orchestrator","tool":"Read","bytes_in":60,"bytes_out":1500}
{"ts":"2026-07-26T10:28:00Z","event":"tool","actor":"orchestrator","role":"orchestrator","tool":"Grep","bytes_in":80,"bytes_out":300}
this line is not json and must be counted as skipped, never silently dropped
`.trim() + '\n';

let passed = 0, failed = 0;
function check(name, fn) {
  try { fn(); passed++; console.log(`  ✓ ${name}`); }
  catch (e) { failed++; console.error(`  ✗ ${name}\n    ${e.message}`); }
}
function run(args) {
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
}
function runJson(args) {
  const r = run([...args, '--json']);
  assert.equal(r.status, 0, `exit 0, got ${r.status}: ${r.stderr}`);
  return JSON.parse(r.stdout);
}

const proj = mkdtempSync(join(tmpdir(), 'atelier-test-'));
mkdirSync(join(proj, '.achilles'), { recursive: true });
const telemetry = join(proj, '.achilles', 'atelier-telemetry.jsonl');
writeFileSync(telemetry, FIXTURE);
writeFileSync(join(proj, '.achilles', 'schema-guard-log.jsonl'),
  '{"ts":"2026-07-26T10:05:01Z","role":"composer","valid":true,"errors":[]}\n' +
  '{"ts":"2026-07-26T10:12:01Z","role":"probe","valid":false,"errors":["missing handover"]}\n');

console.log('— aggregate math (--json)');
const j = runJson(['--project', proj]);
check('schema_version + sizing declared', () => {
  assert.equal(j.schema_version, 2);
  assert.deepEqual(j.sizing, { unit: 'chars', chars_per_token_estimate: 4 });
});
check('dispatch/brief/return totals', () => {
  assert.equal(j.dispatches, 2);
  assert.equal(j.total_brief_bytes, 7000);
  assert.equal(j.total_return_bytes, 10400);
  assert.equal(j.total_brief_tokens_est, 1750);
});
check('leaks counted with exact line pointers', () => {
  assert.equal(j.leaks, 2);
  assert.deepEqual(j.leaks_detail.map(l => l.line).sort(), [5, 6]);
});
check('every leak carries a remediation', () =>
  assert.ok(j.leaks_detail.every(l => (l.remediation || '').length > 40)));
check('per-actor ingest is complete (bash + tools + skills)', () => {
  const o = j.contexts.find(c => c.actor === 'orchestrator');
  assert.equal(o.bytes_out, 2048);
  assert.equal(o.tool_calls, 2);
  assert.equal(o.tool_bytes_out, 1800);
  assert.equal(o.skill_bytes_out, 5000);
  assert.equal(o.total_ingest_bytes, 8848);
});
check('orchestrator window + waste', () => {
  assert.equal(j.orchestrator_window_bytes, 26248);
  assert.equal(j.orchestrator_window_tokens_est, 6562);
  assert.equal(j.leaked_bytes, 11548);
  assert.ok(Math.abs(j.leak_waste_share - 11548 / 26248) < 1e-9);
});
check('worst offenders ranked', () => {
  assert.equal(j.worst_offenders.returns[0].role, 'probe');
  assert.equal(j.worst_offenders.returns[0].leak_channel, 'oversized-return');
  assert.equal(j.worst_offenders.ingest[0].actor, 'orchestrator');
});
check('malformed line surfaced, not dropped', () =>
  assert.equal(j.telemetry_skipped_lines, 1));
check('schema-guard log joined per role', () =>
  assert.equal(j.schema_validity.find(s => s.role === 'probe').invalid, 1));

console.log('— HTML report');
const rHtml = run(['--project', proj]);
const report = join(proj, '.achilles', 'harness-atelier.html');
check('render exits 0 and writes the report', () => {
  assert.equal(rHtml.status, 0);
  assert.ok(existsSync(report));
});
const html = readFileSync(report, 'utf8');
for (const sub of ['harness-atelier', 'Context budget', 'Worst offenders', 'estimated tokens',
  'waste share', 'fix: ', 'malformed telemetry line', 'Context-transfer map', 'Leak panel',
  'bash-ingest', 'oversized-return', 'Tool mix', 'Context by skill'])
  check(`report contains '${sub}'`, () => assert.ok(html.includes(sub)));

console.log('— flow-map cap is stated, never silent');
const capProj = mkdtempSync(join(tmpdir(), 'atelier-cap-'));
const capLog = join(capProj, 't.jsonl');
writeFileSync(capLog, Array.from({ length: 45 }, (_, i) =>
  JSON.stringify({ ts: '2026-07-26T13:00:00Z', event: 'dispatch', actor: 'orchestrator',
    role: 'orchestrator', tool_use_id: `cap${i}`, dispatch_role: 'probe',
    brief_bytes: 100 + i, description: 'probe-cap' })).join('\n') + '\n');
run(['--project', capProj, '--telemetry', capLog, '--out', join(capProj, 'r.html')]);
check('>40 agents → cap note with the full count', () =>
  assert.ok(readFileSync(join(capProj, 'r.html'), 'utf8').includes('40 largest of 45 agents')));

console.log('— baseline diffing (--baseline)');
const baseFile = join(proj, 'baseline.json');
writeFileSync(baseFile, JSON.stringify(j));
check('identity run vs its own baseline → no regressions', () =>
  assert.equal(runJson(['--project', proj, '--baseline', baseFile]).baseline_comparison.regressions.length, 0));
appendFileSync(telemetry, JSON.stringify({ ts: '2026-07-26T10:40:00Z', event: 'command',
  actor: 'orchestrator', role: 'orchestrator', tool: 'Bash', bytes_out: 4096,
  command_head: 'cat tests/e2e/journeys/login.spec.ts',
  leak: { channel: 'bash-ingest', evidence: 'payload dump executed in orchestrator context: cat tests/e2e/journeys/login.spec.ts' } }) + '\n');
const reg = runJson(['--project', proj, '--baseline', baseFile]).baseline_comparison;
check('new leak → leaks + leaked_bytes regress with exact delta', () => {
  assert.ok(reg.regressions.includes('leaks'));
  assert.equal(reg.metrics.find(m => m.metric === 'leaked_bytes').delta, 4096);
  assert.equal(reg.metrics.find(m => m.metric === 'orchestrator_bash_ingest_bytes').regressed, true);
});
check('info metrics never regress', () =>
  assert.equal(reg.metrics.find(m => m.metric === 'dispatches').regressed, false));
check('report renders the vs-baseline section', () => {
  run(['--project', proj, '--baseline', baseFile, '--out', join(proj, 'base.html')]);
  const h = readFileSync(join(proj, 'base.html'), 'utf8');
  assert.ok(h.includes('vs baseline') && h.includes('regressed'));
});
check('unreadable baseline → hard error (exit 1)', () =>
  assert.equal(run(['--project', proj, '--json', '--baseline', join(proj, 'nope.json')]).status, 1));

console.log('— empty project degrades gracefully');
const empty = mkdtempSync(join(tmpdir(), 'atelier-empty-'));
check('no telemetry → exit 0, zero events', () => {
  const e = runJson(['--project', empty]);
  assert.equal(e.events, 0);
});

rmSync(proj, { recursive: true, force: true });
rmSync(capProj, { recursive: true, force: true });
rmSync(empty, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
