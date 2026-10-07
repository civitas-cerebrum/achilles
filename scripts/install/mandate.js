const fs   = require('fs');
const path = require('path');
const { packageDir, projectRoot } = require('./context.js');

// The achilles QA role manifest, read by the kernel at <project>/.claude/kernel-mandate.json.
const QA_MANDATE_FILE = 'achilles-qa.kernel-mandate.json';

// The human-readable copy of the same mandate, hand-maintained against the
// manifest and held to it by scripts/lint-doc-drift.mjs. Staged beside the
// manifest because a project that has an operating system imposed on it
// deserves the page that explains it: every role, what each one is REFUSED,
// where work changes hands, and the review loops. The kernel never reads this
// file — it is for the people.
const QA_LEDGER_FILE = 'achilles-qa.kernel-mandate.md';

// Stage the achilles QA role manifest into the consumer project at
// <project>/.claude/kernel-mandate.json — the path the kernel reads.
//
// Project-scoped and DORMANT: the kernel is reached only through
// achilles-kernel-activation-gate.sh, which consults it while the achilles
// protocol is active in a session and passes through otherwise. Staging the
// file therefore changes nothing for sessions that never run QA; when one
// does, the main session binds as the `orchestrator` role and every
// role-prefixed subagent binds as its own.
//
// NEVER overwrites. A project that already holds a manifest — hand-written,
// `kernel-mandate init`, or a previous install — keeps it, byte for byte;
// the mandate encodes the operator's intent about separation of duties and
// an installer has no business editing it. Writes nowhere else: the only
// destination is inside the project.
function stageProjectMandate(projectDir = projectRoot) {
  if (process.env.CIVITAS_SKIP_HOOK_INSTALL === '1') {
    // No hooks → no kernel to read it; staging would be a stray file.
    return;
  }
  const src = path.join(packageDir, 'hooks', 'data', QA_MANDATE_FILE);
  if (!fs.existsSync(src)) return;
  const destDir = path.join(projectDir, '.claude');
  const dest = path.join(destDir, 'kernel-mandate.json');
  if (fs.existsSync(dest)) {
    console.log(`[civitas-cerebrum] Role manifest already present at ${dest} — left alone (never overwritten).`);
    return;
  }
  fs.mkdirSync(destDir, { recursive: true });
  fs.copyFileSync(src, dest);
  console.log(`[civitas-cerebrum] QA mandate staged at ${dest} — dormant until the achilles protocol activates in a session (main session then binds as \`orchestrator\`).`);

  // The ledger is a hand-kept description of the manifest; lint check 7 holds its role inventory to it.
  // Staged on the same never-overwrite terms as the manifest.
  const ledgerSrc = path.join(packageDir, 'hooks', 'data', QA_LEDGER_FILE);
  const ledgerDest = path.join(destDir, 'kernel-mandate.md');
  if (fs.existsSync(ledgerSrc) && !fs.existsSync(ledgerDest)) {
    fs.copyFileSync(ledgerSrc, ledgerDest);
    console.log(`[civitas-cerebrum] Role ledger staged at ${ledgerDest} — the readable account of that mandate: every role, what each is refused, the handovers and the review loops.`);
  }
}

module.exports = { stageProjectMandate };
