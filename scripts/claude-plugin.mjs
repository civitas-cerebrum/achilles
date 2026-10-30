#!/usr/bin/env node
// Runs `claude plugin <args>` where a Claude Code CLI new enough for hooks modules is on PATH;
// where none is (CI runners, containers, or an older CLI, which npm resolves on Node 20) says so
// and exits 0, so the adapter suite still runs its Node half. Set ACHILLES_REQUIRE_CLAUDE=1 to
// make that a failure.
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const { claudeVersion, atLeast, CLAUDE_MIN } = createRequire(import.meta.url)('../claude-code/register.js');

const args = process.argv.slice(2);
const version = claudeVersion();
if (!atLeast(version, CLAUDE_MIN)) {
  const why = version === null ? '`claude` is not on PATH' : `\`claude\` ${version.join('.')} is older than ${CLAUDE_MIN.join('.')}`;
  const line = `claude-plugin: ${why}; skipped \`claude plugin ${args.join(' ')}\``;
  if (process.env.ACHILLES_REQUIRE_CLAUDE === '1') { console.error(line); process.exit(1); }
  console.log(line);
  process.exit(0);
}
const r = spawnSync('claude', ['plugin', ...args], { stdio: 'inherit' });
process.exit(r.status ?? 1);
