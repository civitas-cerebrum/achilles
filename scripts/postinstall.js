#!/usr/bin/env node

const context = require('./install/context.js');

// Skip when running in the package's own repo (local dev `npm install`).
// The guard only fires when this file is executed directly via `node
// scripts/postinstall.js`. When require()'d (e.g. by scripts/sync-hooks.js
// for an in-repo dev sync), the guard is bypassed and the installers are
// exposed via module.exports for callers to invoke selectively.
if (require.main === module && !context.packageDir.includes('node_modules')) {
  process.exit(0);
}

const { installCivitasSkills } = require('./install/skills.js');
const { installCivitasAgents } = require('./install/agents.js');
const { installCivitasHooks }  = require('./install/hooks.js');
const { installUserTrigger }   = require('./install/user-trigger.js');
const { installBundledJq }     = require('./install/jq.js');
const { installChromium }      = require('./install/chromium.js');

module.exports = {
  installCivitasSkills,
  installCivitasAgents,
  installCivitasHooks,
  installUserTrigger,
  installBundledJq,
  installChromium,
  isGlobalInstall: context.isGlobalInstall,
  harnessClaudeDir: context.harnessClaudeDir,
  skillsDestinations: context.destinations,
  agentsDestinations: context.agentDestinations,
};

// Full postinstall runs only when this file is invoked directly. When
// require()'d, the caller picks which installers to run.
if (require.main === module) {
  (async () => {
    console.log(`[@civitas-cerebrum/achilles] ${context.globalInstall
      ? 'Global install (-g): the harness → ~/.claude (every project).'
      : `Local install: the harness → ${context.harnessClaudeDir} (this project only); the routing skill → ~/.claude/skills/achilles.`}`);

    // Every step writes and records its own files before the next starts, and none fails the
    // install: a non-zero exit makes npm remove the package, and achilles-uninstall with it, after
    // the harness is already on disk.
    const steps = [
      ['skills', () => installCivitasSkills()],
      ['agent definitions', () => installCivitasAgents()],
      ['bundled jq', () => installBundledJq(context.harnessClaudeDir)],
      ['harness hooks', () => installCivitasHooks(context.harnessClaudeDir)],
      ...(context.globalInstall ? [] : [['the user-level routing skill', () => installUserTrigger()]]),
      ['chromium', () => installChromium()],
    ];
    let failed = 0;
    for (const [what, step] of steps) {
      try {
        await step();
      } catch (err) {
        failed++;
        console.warn(`[@civitas-cerebrum/achilles] Could not install ${what}: ${err.message}`);
      }
    }
    if (failed > 0) {
      console.warn(`[@civitas-cerebrum/achilles] Installed with ${failed} step${failed === 1 ? '' : 's'} failed. What was written is recorded; undo it with \`npx achilles-uninstall ${context.globalInstall ? '--global' : '--project'}\`.`);
    }
  })();
}
