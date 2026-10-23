#!/usr/bin/env node
// Runs `claude plugin <args>` where the Claude Code CLI is on PATH; where it is not (CI runners,
// containers) says so and exits 0, so the adapter suite still runs its Node half. Set
// ACHILLES_REQUIRE_CLAUDE=1 to make a missing CLI a failure.
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const { claudeVersion } = createRequire(import.meta.url)('../claude-code/register.js');

const args = process.argv.slice(2);
if (claudeVersion() === null) {
  const line = `claude-plugin: \`claude\` is not on PATH; skipped \`claude plugin ${args.join(' ')}\``;
  if (process.env.ACHILLES_REQUIRE_CLAUDE === '1') { console.error(line); process.exit(1); }
  console.log(line);
  process.exit(0);
}
const r = spawnSync('claude', ['plugin', ...args], { stdio: 'inherit' });
process.exit(r.status ?? 1);
