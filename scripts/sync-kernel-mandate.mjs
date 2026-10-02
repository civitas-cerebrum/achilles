#!/usr/bin/env node
// sync-kernel-mandate.mjs — keep achilles' vendored kernel mandate in lockstep
// with its canonical home, the @civitas-cerebrum/kernel-mandate package
// (github.com/civitas-cerebrum/kernel-mandate).
//
// Why vendoring + sync (instead of resolving from node_modules at
// postinstall time): the vendored files keep every existing surface
// honest with zero installer churn — HOOK_MANIFEST references a file
// that exists in this repo, the hook test suite exercises the exact
// bytes that ship, and lint-doc-drift's bijections keep holding. The
// price of vendoring is drift, and this script is the payment:
//
//   node scripts/sync-kernel-mandate.mjs           # copy canonical → vendored
//   node scripts/sync-kernel-mandate.mjs --check   # diff only; exit 1 on drift
//
// Source resolution: $KERNEL_MANDATE_SRC (a checkout of the canonical repo)
// beats node_modules/@civitas-cerebrum/kernel-mandate. When neither exists
// the script reports and exits 0 — a contributor without the dependency
// installed must not be blocked, drift is caught wherever the
// dependency IS present (prepack runs --check).
//
// NEVER edit the vendored files in this repo — edit upstream, then sync.

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, chmodSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REPO_ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const CHECK = process.argv.includes('--check');

function resolveSource() {
  const env = process.env.KERNEL_MANDATE_SRC;
  if (env && existsSync(join(env, 'hooks/kernel-mandate-role-gate.sh'))) return env;
  const dep = join(REPO_ROOT, 'node_modules', '@civitas-cerebrum', 'kernel-mandate');
  if (existsSync(join(dep, 'hooks/kernel-mandate-role-gate.sh'))) return dep;
  return null;
}

const SRC = resolveSource();
if (!SRC) {
  console.log('[sync-kernel-mandate] canonical source not found ($KERNEL_MANDATE_SRC or node_modules/@civitas-cerebrum/kernel-mandate) — skipping.');
  process.exit(0);
}

// Vendored surface. Directories are synced by *.json / listed-extension
// membership from the SOURCE side (a file present upstream but missing
// here is drift too).
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
// Files vendored under a DIFFERENT path here — the package's own kernel
// test files, which live in their own subdirectory of this repo's cases
// so `npm run test:hooks` gives the vendored kernel identical adversarial
// + benchmark coverage.
//
// DERIVED, not listed. This was a hand-maintained table, and a hand-
// maintained table of "which upstream files matter" is a list that goes
// quietly out of date: every new adversarial-review case file upstream
// was a file this repo's vendored kernel silently stopped being tested
// against, with nothing anywhere to say so.
//
// The subdirectory is the point. These files used to be renumbered into
// the flat cases/ directory with a +70 offset, which gave the vendored
// block twenty-nine slots before it collided with the two-digit
// convention — a ceiling the upstream review loop was going to hit on a
// specific, predictable day. Names now map 1:1 with upstream, there is
// no derivation to get wrong, and there is no ceiling.
const CASES_REL = 'hooks/tests/cases';
const VENDORED_CASES_REL = 'hooks/tests/cases/kernel-mandate';
const RENAMES = readdirSync(join(SRC, CASES_REL))
  .filter((n) => /^\d\d-.+\.sh$/.test(n))
  .sort()
  .map((n) => [join(CASES_REL, n), join(VENDORED_CASES_REL, n)]);
const DIRS = [
  { rel: 'schemas/kernel-mandate.fixtures', ext: '.json' },
  { rel: 'schemas/kernel-mandate-bundle.fixtures', ext: '.json' },
  { rel: 'skills/mandate-designer/examples', ext: '.json' },
];

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

// THE ROLE LEDGER IS DERIVED HERE, not hand-written. The QA mandate is a
// machine artifact; the ledger is its human copy — the ten roles, what each
// one is REFUSED, where work changes hands, the flowchart and the review
// loops — and postinstall stages it beside the manifest so a project that
// has an OS imposed on it also gets the page that explains it. Regenerating
// it from the canonical CLI is the only way it cannot drift from the
// manifest it claims to describe: nobody can improve it by hand, and a hand
// edit shows up here as drift rather than surviving as fiction.
const LEDGER_REL = 'hooks/data/achilles-qa.kernel-mandate.md';
const MANDATE_REL = 'hooks/data/achilles-qa.kernel-mandate.json';
const WORKFLOW_REL = 'hooks/data/achilles-qa.workflow.json';
const kernelCli = join(SRC, 'bin/cli.mjs');
if (existsSync(kernelCli) && existsSync(join(REPO_ROOT, MANDATE_REL))) {
  const tmp = join(REPO_ROOT, 'hooks/data/.achilles-qa.kernel-mandate.md.tmp');
  // Repo-RELATIVE paths, run from the repo root: the ledger names the files
  // it was rendered from, and an absolute path would bake this machine's
  // home directory into a committed file and fail --check everywhere else.
  const r = spawnSync(process.execPath, [kernelCli, 'doc', MANDATE_REL,
    '--workflow', WORKFLOW_REL, '--out', 'hooks/data/.achilles-qa.kernel-mandate.md.tmp', '--quiet'],
  { encoding: 'utf8', cwd: REPO_ROOT });
  if (r.status !== 0) {
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

if (CHECK && drift) {
  console.error(`[sync-kernel-mandate] ${drift} vendored file(s) drifted from ${SRC}.`);
  console.error('Fix: edit upstream (civitas-cerebrum/kernel-mandate), then run: npm run sync:kernel-mandate');
  process.exit(1);
}
console.log(`[sync-kernel-mandate] ${CHECK ? 'check passed' : drift ? `${drift} file(s) updated` : 'already in sync'} (source: ${SRC})`);
