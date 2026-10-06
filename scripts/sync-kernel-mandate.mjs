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
import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REPO_ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const CHECK = process.argv.includes('--check');
const LOCK_MODE = process.argv.includes('--lock');

// The runtime only: the gate and the library it sources. The kernel's schemas,
// design skill and test suite stay upstream.
const FILES = [
  'hooks/kernel-mandate-role-gate.sh',
  'hooks/lib/kernel-mandate.sh',
];

const LOCK_REL = 'scripts/kernel-mandate.lock.json';
const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');

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
  const want = Object.keys(lock.files).sort();
  let drift = 0;
  for (const rel of want) {
    if (!existsSync(join(REPO_ROOT, rel))) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (locked, missing here)`); drift++; }
    else if (sha256(join(REPO_ROOT, rel)) !== lock.files[rel]) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (differs from lock)`); drift++; }
  }
  for (const rel of FILES.filter((r) => !(r in lock.files))) { console.error(`[sync-kernel-mandate] DRIFT: ${rel} (vendored here, not in lock)`); drift++; }
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
if (LOCK_MODE) { writeLock([...FILES], readLock()?.upstream?.commit ?? 'unrecorded'); console.log(`[sync-kernel-mandate] lock written: ${LOCK_REL}`); process.exit(0); }
if (!SRC) {
  if (!CHECK) { console.error('[sync-kernel-mandate] no canonical source ($KERNEL_MANDATE_SRC) — nothing to sync'); process.exit(2); }
  const drift = checkLock();
  console.log(drift ? `[sync-kernel-mandate] ${drift} vendored file(s) drifted from the lock` : '[sync-kernel-mandate] vendored bytes match the lock');
  process.exit(drift ? 1 : 0);
}

let drift = 0;
for (const rel of FILES) {
  const srcPath = join(SRC, rel);
  const dstPath = join(REPO_ROOT, rel);
  const srcBody = readFileSync(srcPath, 'utf8');
  const dstBody = existsSync(dstPath) ? readFileSync(dstPath, 'utf8') : null;
  if (srcBody === dstBody) continue;
  drift++;
  if (CHECK) {
    console.error(`[sync-kernel-mandate] DRIFT: ${rel} ${dstBody === null ? '(missing here)' : 'differs from canonical'}`);
  } else {
    mkdirSync(dirname(dstPath), { recursive: true });
    writeFileSync(dstPath, srcBody);
    if (!rel.includes('/lib/')) chmodSync(dstPath, 0o755);
    console.log(`[sync-kernel-mandate] synced ${rel}`);
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
  writeLock([...FILES], upstreamCommit);
}
console.log(`[sync-kernel-mandate] ${CHECK ? 'check passed' : drift ? `${drift} file(s) updated` : 'already in sync'} (source: ${SRC})`);
