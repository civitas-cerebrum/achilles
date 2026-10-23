#!/usr/bin/env node
// postinstall dispatcher. Three steps, none of which fails the install (a non-zero exit makes
// npm remove the package): the Chromium fetch every harness needs, the Claude Code plugin
// registration (claude-code/register.js), and a one-line pi hint. Nothing is copied into
// ~/.claude or written under ~/.pi: Claude Code loads the plugin in place, pi installs the
// package itself.
'use strict';

const { spawnSync } = require('child_process');
const { installChromium } = require('./install/chromium.js');
const { register, scope } = require('../claude-code/register.js');

const TAG = '[@civitas-cerebrum/achilles]';

function piHint() {
  const pi = spawnSync('pi', ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  if (!pi || pi.status !== 0) return;
  console.log(`${TAG} pi ${String(pi.stdout).trim()} found: load the skills with \`pi install npm:@civitas-cerebrum/achilles\` (user-wide) or \`pi install ./node_modules/@civitas-cerebrum/achilles --local\` (this project).`);
}

async function main() {
  // A developer's `npm install` inside this checkout installs nothing.
  const s = scope();
  if (s.isOwnCheckout && !s.isGlobal) return;
  const steps = [
    ['chromium', () => installChromium()],
    ['Claude Code registration', () => register()],
    ['the pi hint', () => piHint()],
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
