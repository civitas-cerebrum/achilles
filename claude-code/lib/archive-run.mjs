#!/usr/bin/env node
// archive-run.mjs — the reporting hook's archive backstop: after a Playwright run, copy the run's
// artefacts into .achilles/runs/<runId>/ unless the Achilles reporter (or an earlier backstop)
// already claimed exactly this candidate set. Copies only; never deletes a consumer's file.
//
// Usage: node archive-run.mjs <projectRoot> [--output <dir>] [--json <file>] [--trigger <label>]
// Env:   ACHILLES_ARTIFACT_RETAIN (default 5; 0 disables), ACHILLES_ARTIFACT_MAX_MB (default 512:
//        above it, traces and videos are skipped and named)
// Prints {"archived":false,"why":"…"} or {"archived":true,"runId","files","skipped":[…],"pruned":[…],"incomplete":bool}.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { allocateRunId, claimFile, pruneRuns, runsDir, updateLatest } = require('../../reporter/lib/archive.js');
const { statCandidates } = require('../../reporter/lib/paths.js');

const args = process.argv.slice(2);
const root = path.resolve(args[0] ?? '.');
const opt = (name) => { const i = args.indexOf(name); return i > 0 ? args[i + 1] : undefined; };
const say = (o) => { process.stdout.write(JSON.stringify(o)); process.exit(0); };
const intEnv = (name, d) => { const v = Number.parseInt(process.env[name] ?? '', 10); return Number.isFinite(v) && v >= 0 ? v : d; };

const retain = intEnv('ACHILLES_ARTIFACT_RETAIN', 5);
if (retain === 0) say({ archived: false, why: 'ACHILLES_ARTIFACT_RETAIN=0' });
const maxBytes = intEnv('ACHILLES_ARTIFACT_MAX_MB', 512) * 1024 * 1024;

// Candidates: --output, else the config's outputDir, else test-results; the html report folder; a json report.
const config = ['playwright.config.ts', 'playwright.config.js', 'playwright.config.mjs'].map((f) => path.join(root, f)).find((f) => fs.existsSync(f));
const configText = config ? fs.readFileSync(config, 'utf8') : '';
const grab = (key) => new RegExp(`${key}\\s*:\\s*['"\`]([^'"\`]+)['"\`]`).exec(configText)?.[1];
const candidates = [];
const add = (rel, kind, resolvedFrom) => {
  if (!rel) return;
  const r = path.relative(root, path.resolve(root, rel)).split(path.sep).join('/');
  if (r === '' || r.startsWith('..') || !fs.existsSync(path.join(root, r))) return;
  if (candidates.some((c) => c.path === r || r.startsWith(`${c.path}/`))) return;
  candidates.push({ path: r, kind, resolvedFrom });
};
if (opt('--output')) add(opt('--output'), 'outputDir', 'cli:--output');
else if (grab('outputDir')) add(grab('outputDir'), 'outputDir', `config:${path.basename(config)}:outputDir`);
else add('test-results', 'outputDir', 'default');
add(grab('outputFolder') ?? 'playwright-report', 'htmlReport', grab('outputFolder') ? `config:${path.basename(config)}:outputFolder` : 'default');
if (opt('--json')) add(opt('--json'), 'jsonReport', 'cli:PLAYWRIGHT_JSON_OUTPUT_NAME');
if (candidates.length === 0) say({ archived: false, why: 'no artefacts on disk' });

const stats = statCandidates(root, candidates);
if (stats.files === 0) say({ archived: false, why: 'no artefacts on disk' });
let claim;
try { claim = JSON.parse(fs.readFileSync(claimFile(root), 'utf8')); } catch { claim = undefined; }
const covered = claim && claim.complete === true && ['reporter', 'hook'].includes(claim.claimedBy) && candidates.every((c) => {
  const a = claim.candidates?.byPath?.[c.path];
  const b = stats.byPath[c.path];
  return a && a.files === b.files && a.bytes === b.bytes && a.newestMtime === b.newestMtime;
});
if (covered) say({ archived: false, why: `already archived by the ${claim.claimedBy}` });

const runId = allocateRunId(root);
const dest = path.join(runsDir(root), runId);
const reduced = stats.bytes > maxBytes;
const skipped = [];
let copied = 0;
let expected = 0;
const copy = (abs, rel) => {
  const st = fs.lstatSync(abs);
  if (st.isSymbolicLink()) return;
  if (st.isDirectory()) { for (const n of fs.readdirSync(abs)) copy(path.join(abs, n), `${rel}/${n}`); return; }
  if (!st.isFile()) return;
  if (reduced && /\.(zip|webm|mp4)$/.test(abs)) { skipped.push({ path: rel, bytes: st.size }); return; }
  expected += 1;
  try {
    const to = path.join(dest, 'artifacts', rel);
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(abs, to);
    copied += 1;
  } catch { /* counted as incomplete below */ }
};
try {
  for (const c of candidates) copy(path.join(root, c.path), c.path);
  fs.mkdirSync(dest, { recursive: true });
  fs.writeFileSync(path.join(dest, 'manifest.json'), `${JSON.stringify({
    schema: 'playwright-run-archive/v1', runId, trigger: opt('--trigger') ?? 'hook', mode: reduced ? 'reduced' : 'full',
    sources: candidates, counts: { expectedFiles: expected, archivedFiles: copied }, skipped, incomplete: copied < expected,
  }, null, 2)}\n`);
} catch (e) {
  say({ archived: false, why: `the archive could not be written (${e.code ?? e.message})` });
}
const pruned = pruneRuns(root, retain);
updateLatest(root, runId);
if (copied === expected) {
  fs.writeFileSync(claimFile(root), `${JSON.stringify({ fingerprint: `hook:${runId}`, runId, claimedBy: 'hook', complete: true, candidates: { paths: candidates.map((c) => c.path), ...stats } }, null, 2)}\n`);
}
say({ archived: true, runId, files: copied, skipped, pruned, incomplete: copied < expected });
