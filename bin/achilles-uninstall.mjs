#!/usr/bin/env node
// achilles-uninstall [--global] [--project <dir>] [--dry-run]
// Reverses what postinstall recorded in <claude dir>/achilles-install.json: its
// settings.json registrations, then its files (only those still byte-identical to
// what was written), the staged mandate (only when unedited), and last the record.
// npm >= 7 runs no uninstall lifecycle script, so this is a command.
import { createRequire } from 'node:module';
import { existsSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';

const require = createRequire(import.meta.url);
const { RECORD_FILE, sha256, openRecord, removeRecorded, dropStaleRegistrations } = require('../scripts/install/record.js');
const { STAMP_FILE } = require('../scripts/install/mandate.js');
const { userClaudeDir } = require('../scripts/install/context.js');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const projectAt = args.indexOf('--project');
const unknown = args.filter((a, i) => !['--global', '--dry-run', '--project'].includes(a) && args[i - 1] !== '--project');
if (unknown.length || (projectAt >= 0 && !args[projectAt + 1]) || (flag('--global') && projectAt >= 0)) {
  console.error('usage: achilles-uninstall [--global | --project <dir>] [--dry-run]');
  process.exit(2);
}

const dryRun = flag('--dry-run');
const projectDir = resolve(projectAt >= 0 ? args[projectAt + 1] : process.cwd());
const claudeDir = flag('--global') ? userClaudeDir : join(projectDir, '.claude');
const say = (verb, what) => console.log(`${dryRun ? 'would ' : ''}${verb} ${what}`);

if (!existsSync(join(claudeDir, RECORD_FILE))) {
  console.error(`achilles-uninstall: no ${RECORD_FILE} in ${claudeDir}; nothing recorded.`);
  process.exit(1);
}
const rec = openRecord(claudeDir);

const settingsPath = join(claudeDir, 'settings.json');
if (existsSync(settingsPath) && rec.prevRegistrations.length > 0) {
  try {
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    if (dropStaleRegistrations(rec, settings)) {
      say('remove', `${rec.prevRegistrations.length} recorded registrations from ${settingsPath}`);
      if (!dryRun) writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    }
  } catch (err) {
    console.warn(`achilles-uninstall: ${settingsPath} is not valid JSON; registrations left in place. (${err.message})`);
  }
}

for (const [rel, hash] of Object.entries(rec.prev)) {
  const file = join(claudeDir, rel);
  const probe = removeRecorded(claudeDir, rel, hash, dryRun);
  if (probe.state === 'removed') say('remove', file);
  else if (probe.state === 'modified') console.warn(`kept ${file}: modified after install`);
}

// The staged mandate lives in the project, not beside the hooks of a global install.
const stampPath = join(claudeDir, STAMP_FILE);
if (!flag('--global') && existsSync(stampPath)) {
  let stamp = {};
  try { stamp = JSON.parse(readFileSync(stampPath, 'utf8')) ?? {}; } catch { /* unreadable stamp: keep the mandate */ }
  for (const [name, key] of [['kernel-mandate.json', 'manifestSha256'], ['kernel-mandate.md', 'ledgerSha256']]) {
    const file = join(claudeDir, name);
    if (!existsSync(file)) continue;
    if (stamp[key] === sha256(file)) {
      say('remove', file);
      if (!dryRun) unlinkSync(file);
    } else {
      console.warn(`kept ${file}: edited, or not staged by achilles`);
    }
  }
  say('remove', stampPath);
  if (!dryRun) unlinkSync(stampPath);
}

say('remove', join(claudeDir, RECORD_FILE));
if (!dryRun) unlinkSync(join(claudeDir, RECORD_FILE));
