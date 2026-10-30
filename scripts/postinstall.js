#!/usr/bin/env node
// postinstall dispatcher. Three steps, none of which fails the install (a non-zero exit makes
// npm remove the package): the Chromium fetch every harness needs, the Claude Code plugin
// registration (claude-code/register.js), and the pi package registration when pi is on PATH.
// Nothing is copied into ~/.claude or ~/.pi: both harnesses load the package in place.
'use strict';

const { spawnSync } = require('child_process');
const { installChromium } = require('./install/chromium.js');
const { register, scope } = require('../claude-code/register.js');

const TAG = '[@civitas-cerebrum/achilles]';

// pi on PATH: install this package as a pi package, so pi loads the skills and the extension
// (pi/index.ts: delegate_qa, expert mode, the guards). A project install goes into the project's
// .pi/settings.json (`--local`), a global one user-wide. pi loads a local package in place.
function piRegister(s) {
  if (process.env.ACHILLES_SKIP_PI_REGISTRATION === '1') return;
  const pi = spawnSync('pi', ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  if (!pi || pi.status !== 0) return;
  // --approve: pi's one-time trust decision for this command, which the user's own npm install asked for.
  const args = ['install', s.packageDir, ...(s.isGlobal ? [] : ['--local', '--approve'])];
  const r = spawnSync('pi', args, { cwd: s.projectRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 });
  if (r.status === 0) console.log(`${TAG} pi ${String(pi.stdout).trim()}: Achilles installed as a pi package (${s.isGlobal ? 'user-wide' : 'this project'}); it loads at the next pi session${s.isGlobal ? '' : ' once the project is trusted'}.`);
  else console.warn(`${TAG} pi found, but \`pi ${args.join(' ')}\` failed${r.stderr ? `: ${String(r.stderr).trim().split('\n')[0]}` : ''}. Run it by hand to load Achilles in pi.`);
}

async function main() {
  // A developer's `npm install` inside this checkout installs nothing.
  const s = scope();
  if (s.isOwnCheckout && !s.isGlobal) return;
  const steps = [
    ['chromium', () => installChromium()],
    ['Claude Code registration', () => register()],
    ['pi registration', () => piRegister(s)],
  ];
  for (const [what, step] of steps) {
    try {
      await step();
    } catch (err) {
      console.warn(`${TAG} Could not finish ${what}: ${err.message}`);
    }
  }
}

if (require.main === module) main();

module.exports = { main };
