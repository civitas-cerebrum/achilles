// The archive backstop the reporting hook runs after a Playwright run, against the 0.2.x spec 80:
// discovery, the second run not destroying the first, idempotency, the reporter's claim,
// retention, the size ceiling and copy-never-move.
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const script = path.join(__dirname, '../../../lib/archive-run.mjs');
const archive = (dir, env = {}, extra = []) => JSON.parse(spawnSync(process.execPath, [script, dir, ...extra], { encoding: 'utf8', env: { ...process.env, ...env } }).stdout || '{}');
const runs = (dir) => { try { return fs.readdirSync(path.join(dir, '.achilles/runs')).filter((n) => /^\d{8}T\d{6}Z/.test(n)).sort(); } catch { return []; } };
const put = (dir, rel, text) => { fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true }); fs.writeFileSync(path.join(dir, rel), text); };
function project() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-'));
  put(d, 'playwright.config.ts', "export default { outputDir: './pw-artifacts', reporter: [['html', { outputFolder: './pw-html' }]] };");
  put(d, 'pw-artifacts/spec-failing/trace.zip', 'trace-1');
  put(d, 'pw-artifacts/spec-failing/error-context.md', '# Error context');
  put(d, 'pw-artifacts/spec-failing-retry1/trace.zip', 'retry-trace');
  put(d, 'pw-html/results.json', '{"stats":{}}');
  return d;
}

let failed = 0;
const check = (name, ok) => { if (!ok) failed++; console[ok ? 'log' : 'error'](`  ${ok ? '✓' : '✗'} ${name}`); };

const a = project();
const r1 = archive(a);
const run1 = path.join(a, '.achilles/runs', r1.runId ?? 'x');
check('archives a run, discovering outputDir and the html report from the config', r1.archived && fs.existsSync(path.join(run1, 'artifacts/pw-artifacts/spec-failing/trace.zip')) && fs.existsSync(path.join(run1, 'artifacts/pw-html/results.json')));
check('every retry attempt travels with its own directory', fs.readFileSync(path.join(run1, 'artifacts/pw-artifacts/spec-failing-retry1/trace.zip'), 'utf8') === 'retry-trace');
check('copies, never moves', fs.existsSync(path.join(a, 'pw-artifacts/spec-failing/trace.zip')));
check('an unchanged candidate set is a no-op', archive(a).archived === false && runs(a).length === 1);
fs.rmSync(path.join(a, 'pw-artifacts'), { recursive: true });
put(a, 'pw-artifacts/spec-failing/trace.zip', 'second-run-trace-longer');
const r2 = archive(a);
check("a second run cannot destroy the first run's evidence", r2.archived && fs.readFileSync(path.join(run1, 'artifacts/pw-artifacts/spec-failing/trace.zip'), 'utf8') === 'trace-1' && runs(a).length === 2);

const b = project();
const stats = require('../../../../reporter/lib/paths.js').statCandidates(b, [{ path: 'pw-artifacts' }, { path: 'pw-html' }]);
put(b, '.achilles/runs/.last-archive.json', JSON.stringify({ claimedBy: 'reporter', complete: true, candidates: { byPath: stats.byPath } }));
check("a matching reporter claim suppresses the backstop", archive(b).archived === false && runs(b).length === 0);
put(b, '.achilles/runs/.last-archive.json', JSON.stringify({ claimedBy: 'reporter', complete: false, candidates: { byPath: stats.byPath } }));
check('an incomplete claim does not', archive(b).archived === true);

const c = project();
for (const m of ['x', 'xx', 'xxx']) { put(c, 'pw-artifacts/spec-failing/trace.zip', m); archive(c, { ACHILLES_ARTIFACT_RETAIN: '2' }); }
check('retention keeps the newest runs and names what it pruned', runs(c).length === 2);
check('ACHILLES_ARTIFACT_RETAIN=0 disables the backstop', archive(project(), { ACHILLES_ARTIFACT_RETAIN: '0' }).archived === false);
const d = project();
const rd = archive(d, { ACHILLES_ARTIFACT_MAX_MB: '0' });
check('over the size ceiling, traces and videos are skipped and named; the rest is kept', rd.archived && rd.skipped.length === 2 && fs.existsSync(path.join(d, '.achilles/runs', rd.runId, 'artifacts/pw-artifacts/spec-failing/error-context.md')));
const e = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-'));
put(e, 'test-results/spec-y/trace.zip', 'default');
check('no config: the Playwright default outputDir', archive(e).archived === true);
check('a project with no artefacts archives nothing', archive(fs.mkdtempSync(path.join(os.tmpdir(), 'archive-'))).archived === false);
const f = project();
put(f, 'cli-out/spec-x/trace.zip', 'cli');
const rf = archive(f, {}, ['--output', 'cli-out']);
check('--output on the command line beats the config', fs.existsSync(path.join(f, '.achilles/runs', rf.runId, 'artifacts/cli-out/spec-x/trace.zip')));

console.log(`\n${failed === 0 ? 'all' : failed} ${failed === 0 ? 'passed' : 'failed'}`);
process.exit(failed === 0 ? 0 : 1);
