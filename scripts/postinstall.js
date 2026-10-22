#!/usr/bin/env node

const context = require('./install/context.js');

// Skip a developer's `npm install` inside this package's own checkout, where
// INIT_CWD is the package dir. A folder install (`npm install <path>`) links
// the package, so its path has no node_modules in it, yet it is a consumer
// install and must run; a global install always runs. The guard only fires
// when this file is executed directly; when require()'d (e.g. by
// scripts/sync-hooks.js), the installers are exposed via module.exports.
if (require.main === module && context.isOwnCheckout() && !context.globalInstall) {
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
