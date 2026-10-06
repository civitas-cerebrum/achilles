#!/usr/bin/env node
// sync-kernel-mandate.mjs — vendored copy of civitas-cerebrum/kernel-mandate.
//
//   node scripts/sync-kernel-mandate.mjs            copy $KERNEL_MANDATE_SRC → repo, rewrite the lock
//   node scripts/sync-kernel-mandate.mjs --check    exit 1 if vendored bytes differ from the lock
//                                                   (and from $KERNEL_MANDATE_SRC when set)
//   node scripts/sync-kernel-mandate.mjs --lock     rewrite the lock from the current vendored bytes
//
// Vendored files are never edited here; change them upstream and sync.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, chmodSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REPO_ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const CHECK = process.argv.includes('--check');
const LOCK_MODE = process.argv.includes('--lock');

// Files copied to the same relative path in this repo.
const FILES = [
  'hooks/kernel-mandate-role-gate.sh',
  'hooks/lib/kernel-mandate.sh',
  'schemas/kernel-mandate.schema.json',
  'schemas/kernel-mandate-bundle.schema.json',
  'skills/mandate-designer/SKILL.md',
  'skills/mandate-designer/references/architecture.md',
  'skills/mandate-designer/references/storage-format.md',
];
// Upstream case files map 1:1 into hooks/tests/cases/kernel-mandate/.
const CASES_REL = 'hooks/tests/cases';
const VENDORED_CASES_REL = 'hooks/tests/cases/kernel-mandate';
const DIRS = [
  { rel: 'schemas/kernel-mandate.fixtures', ext: '.json' },
  { rel: 'schemas/kernel-mandate-bundle.fixtures', ext: '.json' },
  { rel: 'skills/mandate-designer/examples', ext: '.json' },
];

const LOCK_REL = 'scripts/kernel-mandate.lock.json';
const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');

function vendoredFromRepo() {
  const out = [...FILES];
  for (const n of readdirSync(join(REPO_ROOT, VENDORED_CASES_REL)).filter((n) => /^\d\d-.+\.sh$/.test(n)).sort()) out.push(join(VENDORED_CASES_REL, n));
  for (const d of DIRS) for (const f of readdirSync(join(REPO_ROOT, d.rel)).filter((n) => n.endsWith(d.ext)).sort()) out.push(join(d.rel, f));
  return out.sort();
}
function readLock() {
  try { return JSON.parse(readFileSync(join(REPO_ROOT, LOCK_REL), 'utf8')); } catch { return null; }
}
function writeLock(paths, commit) {
  const files = Object.fromEntries(paths.sort().map((rel) => [rel, sha256(join(REPO_ROOT, rel))]));
  writeFileSync(join(REPO_ROOT, LOCK_REL), JSON.stringify({ upstream: { repo: 'civitas-cerebrum/kernel-mandate', commit }, files }, null, 2) + '\n');
}
function checkLock() {
  const lock = readLock();
  if (!lock?.files) { console.error(`[sync-kernel-mandate] no lock at ${LOCK_REL} — run with --lock after a verified sync`); process.exit(2); }
  const want = Object.keys(lock.files).sort(); const have = vendoredFromRepo();
  let drift = 0;
  for (const rel of want) {
    if (!existsSync(join(REPO_ROOT, rel))) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (locked, missing here)`); drift++; }
    else if (sha256(join(REPO_ROOT, rel)) !== lock.files[rel]) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (differs from lock)`); drift++; }
  }
  for (const rel of have.filter((r) => !(r in lock.files))) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (vendored here, not in lock)`); drift++; }
  return drift;
}

function resolveSource() {
  const env = process.env.KERNEL_MANDATE_SRC;
  if (env && existsSync(join(env, 'hooks/kernel-mandate-role-gate.sh'))) return env;
  const dep = join(REPO_ROOT, 'node_modules', '@civitas-cerebrum', 'kernel-mandate');
  if (existsSync(join(dep, 'hooks/kernel-mandate-role-gate.sh'))) return dep;
  return null;
}

const SRC = resolveSource();
if (LOCK_MODE) { writeLock(vendoredFromRepo(), readLock()?.upstream?.commit ?? 'unrecorded'); console.log(`[sync-kernel-mandate] lock written: ${LOCK_REL}`); process.exit(0); }
if (!SRC) {
  if (!CHECK) { console.error('[sync-kernel-mandate] no canonical source ($KERNEL_MANDATE_SRC) — nothing to sync'); process.exit(2); }
  const drift = checkLock();
  console.log(drift ? `[sync-kernel-mandate] ${drift} vendored file(s) drifted from the lock` : '[sync-kernel-mandate] vendored bytes match the lock');
  process.exit(drift ? 1 : 0);
}

const RENAMES = readdirSync(join(SRC, CASES_REL))
  .filter((n) => /^\d\d-.+\.sh$/.test(n))
  .sort()
  .map((n) => [join(CASES_REL, n), join(VENDORED_CASES_REL, n)]);
const targets = FILES.map((f) => [f, f]);
for (const [s, d] of RENAMES) targets.push([s, d]);
for (const d of DIRS) {
  for (const f of readdirSync(join(SRC, d.rel)).filter((n) => n.endsWith(d.ext))) {
    targets.push([join(d.rel, f), join(d.rel, f)]);
  }
}

let drift = 0;
for (const [srcRel, dstRel] of targets) {
  const srcPath = join(SRC, srcRel);
  const dstPath = join(REPO_ROOT, dstRel);
  const srcBody = readFileSync(srcPath, 'utf8');
  const dstBody = existsSync(dstPath) ? readFileSync(dstPath, 'utf8') : null;
  if (srcBody === dstBody) continue;
  drift++;
  if (CHECK) {
    console.error(`[sync-kernel-mandate] DRIFT: ${dstRel} ${dstBody === null ? '(missing here)' : 'differs from canonical'}`);
  } else {
    mkdirSync(dirname(dstPath), { recursive: true });
    writeFileSync(dstPath, srcBody);
    if (dstRel.endsWith('.sh') && !dstRel.includes('/lib/')) chmodSync(dstPath, 0o755);
    console.log(`[sync-kernel-mandate] synced ${dstRel}`);
  }
}

// The role ledger is RE-DERIVED here when a canonical source is available.
// The QA mandate is a machine artifact; the ledger is its human copy — the
// roles, what each one is REFUSED, where work changes hands, the flowchart
// and the review loops — and postinstall stages it beside the manifest so a
// project that has an OS imposed on it also gets the page that explains it.
// A fresh render is the only thing that can reproduce the sections that are
// a cross-product of the role set, so this block overwrites the committed
// ledger wholesale and that is intended.
//
// Without a canonical source none of this runs, so the committed ledger is
// hand-maintained: its role inventory is the part a human can keep correct,
// and lint-doc-drift's inventory check fails the build when it is not. Its
// cross-product sections carry an in-place note saying which render they
// came from, because nobody can honestly hand-write them.
const LEDGER_REL = 'hooks/data/achilles-qa.kernel-mandate.md';
const MANDATE_REL = 'hooks/data/achilles-qa.kernel-mandate.json';
const WORKFLOW_REL = 'hooks/data/achilles-qa.workflow.json';
const kernelCli = join(SRC, 'bin/cli.mjs');
const RENDER_BUDGET_MS = 60_000;
if (existsSync(kernelCli) && existsSync(join(REPO_ROOT, MANDATE_REL))) {
  const tmp = join(REPO_ROOT, 'hooks/data/.achilles-qa.kernel-mandate.md.tmp');
  // Repo-RELATIVE paths, run from the repo root: the ledger names the files
  // it was rendered from, and an absolute path would bake this machine's
  // home directory into a committed file and fail --check everywhere else.
  const r = spawnSync(process.execPath, [kernelCli, 'doc', MANDATE_REL,
    '--workflow', WORKFLOW_REL, '--out', 'hooks/data/.achilles-qa.kernel-mandate.md.tmp', '--quiet'],
  { encoding: 'utf8', cwd: REPO_ROOT, timeout: RENDER_BUDGET_MS, killSignal: 'SIGKILL' });
  if (r.error?.code === 'ETIMEDOUT') {
    rmSync(tmp, { force: true });
    console.warn(`[sync-kernel-mandate] WARNING: role-ledger render exceeded ${RENDER_BUDGET_MS / 1000}s (upstream docCycles blowup); keeping the committed ledger.`);
  } else if (r.status !== 0) {
    console.error(`[sync-kernel-mandate] could not render the role ledger: ${(r.stderr || r.stdout || '').trim().slice(0, 300)}`);
    drift++;
  } else {
    const fresh = readFileSync(tmp, 'utf8');
    const have = existsSync(join(REPO_ROOT, LEDGER_REL)) ? readFileSync(join(REPO_ROOT, LEDGER_REL), 'utf8') : null;
    rmSync(tmp, { force: true });
    if (fresh !== have) {
      drift++;
      if (CHECK) console.error(`[sync-kernel-mandate] DRIFT: ${LEDGER_REL} ${have === null ? '(missing here)' : 'differs from a fresh render'}`);
      else { writeFileSync(join(REPO_ROOT, LEDGER_REL), fresh); console.log(`[sync-kernel-mandate] rendered ${LEDGER_REL}`); }
    }
  }
}

if (CHECK) drift += checkLock();
if (CHECK && drift) {
  console.error(`[sync-kernel-mandate] ${drift} vendored file(s) drifted from ${SRC}.`);
  console.error('Fix: edit upstream (civitas-cerebrum/kernel-mandate), then run: npm run sync:kernel-mandate');
  process.exit(1);
}
if (!CHECK) {
  const upstreamCommit = spawnSync('git', ['-C', SRC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout?.trim() || 'unknown';
  writeLock(targets.map(([, d]) => d), upstreamCommit);
}
console.log(`[sync-kernel-mandate] ${CHECK ? 'check passed' : drift ? `${drift} file(s) updated` : 'already in sync'} (source: ${SRC})`);
