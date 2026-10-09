const fs     = require('fs');
const path   = require('path');
const { packageDir: ownPackageDir, projectRoot } = require('./context.js');
const { sha256 } = require('./record.js');

// The achilles QA role manifest, read by the kernel at <project>/.claude/kernel-mandate.json,
// and the human-readable copy of the same mandate, hand-maintained against the
// manifest and held to it by scripts/lint-doc-drift.mjs. The kernel never reads the
// ledger; it is the page that explains every role, what each is REFUSED, where work
// changes hands, and the review loops.
const QA_MANDATE_FILE = 'achilles-qa.kernel-mandate.json';
const QA_LEDGER_FILE = 'achilles-qa.kernel-mandate.md';
const STAMP_FILE = 'kernel-mandate.achilles.json';

// Stage one file at <dest>; `stamped` is the hash recorded when it was last staged.
//   absent                             → staged
//   unchanged since staged             → refreshed to the package's version
//   edited since staged, or never staged (a hand-written manifest, `kernel-mandate init`,
//   a pre-stamp install)               → left byte for byte; the package's version is
//                                        written beside it as <name>.achilles-new.<ext>
// The mandate encodes the operator's intent about separation of duties; an installer
// has no business editing it. Returns [outcome, hash to stamp] with outcome one of
// 'staged' | 'refreshed' | 'kept' | 'same'.
function stageOne(src, dest, stamped, version) {
  const want = sha256(src);
  const newCopy = dest.replace(/(\.[^.]+)$/, '.achilles-new$1');
  if (!fs.existsSync(dest)) {
    fs.copyFileSync(src, dest);
    return ['staged', want];
  }
  const have = sha256(dest);
  if (have === want || stamped === have) {
    const outcome = have === want ? 'same' : 'refreshed';
    if (outcome === 'refreshed') fs.copyFileSync(src, dest);
    fs.rmSync(newCopy, { force: true });
    return [outcome, want];
  }
  if (!fs.existsSync(newCopy) || sha256(newCopy) !== want) {
    fs.copyFileSync(src, newCopy);
    console.log(`[civitas-cerebrum] Kept your ${dest}; the ${version} QA mandate is at ${newCopy}.`);
  }
  return ['kept', stamped];
}

// Project-scoped and DORMANT: the kernel is reached only through
// achilles-kernel-activation-gate.sh, which consults it while the achilles
// protocol is active in a session and passes through otherwise. Writes nowhere
// but <project>/.claude/.
function stageProjectMandate(projectDir = projectRoot, { packageDir = ownPackageDir } = {}) {
  if (process.env.CIVITAS_SKIP_HOOK_INSTALL === '1') {
    // No hooks → no kernel to read it; staging would be a stray file.
    return;
  }
  const manifestSrc = path.join(packageDir, 'hooks', 'data', QA_MANDATE_FILE);
  if (!fs.existsSync(manifestSrc)) return;
  const destDir = path.join(projectDir, '.claude');
  fs.mkdirSync(destDir, { recursive: true });
  const stampPath = path.join(destDir, STAMP_FILE);
  let stamp = null;
  try { stamp = JSON.parse(fs.readFileSync(stampPath, 'utf8')); } catch (_) { /* first stage */ }
  if (stamp === null || typeof stamp !== 'object') stamp = {};
  const version = JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8')).version;

  const staged = { version };
  const [manifestOutcome, manifestHash] = stageOne(manifestSrc, path.join(destDir, 'kernel-mandate.json'), stamp.manifestSha256, version);
  if (manifestHash) staged.manifestSha256 = manifestHash;
  const note = (outcome, what) => {
    if (outcome === 'staged') console.log(`[civitas-cerebrum] ${what} staged in ${destDir} — dormant until the achilles protocol activates in a session (main session then binds as \`orchestrator\`).`);
    if (outcome === 'refreshed') console.log(`[civitas-cerebrum] ${what} refreshed in ${destDir} (you had not edited it).`);
  };
  note(manifestOutcome, 'QA mandate');
  const ledgerSrc = path.join(packageDir, 'hooks', 'data', QA_LEDGER_FILE);
  if (fs.existsSync(ledgerSrc)) {
    const [ledgerOutcome, ledgerHash] = stageOne(ledgerSrc, path.join(destDir, 'kernel-mandate.md'), stamp.ledgerSha256, version);
    if (ledgerHash) staged.ledgerSha256 = ledgerHash;
    note(ledgerOutcome, 'Role ledger');
  }
  const text = JSON.stringify(staged, null, 2) + '\n';
  if (!fs.existsSync(stampPath) || fs.readFileSync(stampPath, 'utf8') !== text) fs.writeFileSync(stampPath, text);
}

module.exports = { stageProjectMandate, STAMP_FILE };
