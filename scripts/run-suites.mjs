#!/usr/bin/env node
// `npm test`: runs every suite even when an earlier one fails, then exits non-zero if any failed.
// Keep this list and the steps of .github/workflows/ci.yml in step: one step per suite.
import { spawnSync } from 'node:child_process';

const SUITES = [
  ['schemas', 'schemas:lint'],
  ['lock', 'test:lock'],
  ['lint', 'test:lint'],
  ['hooks', 'test:hooks'],
  ['factory', 'test:factory'],
  ['bin', 'test:bin'],
  ['reporter', 'test:reporter'],
  ['agents', 'test:agents'],
];

const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const results = SUITES.map(([name, script]) => {
  console.log(`\n=== ${name}: npm run ${script} ===`);
  const r = spawnSync(npm, ['run', script], { stdio: 'inherit' });
  return { name, code: r.status ?? 1 };
});

console.log('\n=== suites ===');
for (const { name, code } of results) console.log(`${code === 0 ? 'PASS' : 'FAIL'}  ${name}${code === 0 ? '' : ` (exit ${code})`}`);
process.exit(results.some((r) => r.code !== 0) ? 1 : 0);
