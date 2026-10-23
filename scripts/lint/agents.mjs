import { spawnSync } from 'node:child_process';

// Check 10 — agents/*.md are exactly what build-agents.mjs renders from the mandate
export function run(report) {
  const r = spawnSync(process.execPath, ['scripts/build-agents.mjs', '--check'], { encoding: 'utf8' });
  report('agents/*.md ↔ QA mandate roles (build-agents.mjs --check)', r.status === 0,
    r.status === 0 ? [] : (r.stderr || r.stdout).trim().split('\n'));
}
