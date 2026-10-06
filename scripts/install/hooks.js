const fs   = require('fs');
const path = require('path');
const { packageDir, userClaudeDir } = require('./context.js');

// Install the achilles harness hooks into <claudeDir>/hooks/ and register
// them in <claudeDir>/settings.json — ~/.claude for a global (-g) install,
// <project>/.claude for a local one (see context.js). Markdown rules in the
// skills are skippable; the harness-level hooks are not.
//
// hooks/data/hook-manifest.json:
//   hooks          — registrations, each { file, event, matcher, timeout, async? }:
//     file     — script name in <package>/hooks/, copied to <claudeDir>/hooks/<file>
//     event    — PreToolUse | PostToolUse | SubagentStop | Stop | …
//     matcher  — tool-name match string for the event (null for events without
//                matchers, e.g. SubagentStop)
//     timeout  — seconds the harness waits before killing the hook
//     async    — true for fire-and-forget hooks (used for cleanup)
//   companions     — scripts copied beside the hooks but NEVER registered: a
//                    registered hook execs them. The kernel mandate kernel is
//                    one — achilles-kernel-activation-gate.sh execs it only while
//                    the achilles protocol is active; registered directly it
//                    would govern every session in the project unconditionally.
//   legacyEiHooks  — hooks this package shipped once and no longer does; an
//                    upgrade deletes them and their registrations.
// What each hook enforces: skills/achilles-protocol/references/harness-hooks.md.
//
// Idempotent:
//   - Each hook file is copied iff missing or older than the bundled version.
//   - Each settings.json entry is added iff a matching {event, matcher, command}
//     triple is not already registered. Pre-existing user hooks are preserved.
//
// Opt-out: set CIVITAS_SKIP_HOOK_INSTALL=1 — useful for enterprise managed
// settings where postinstall scripts must not modify ~/.claude/settings.json.
const manifest = JSON.parse(fs.readFileSync(path.join(packageDir, 'hooks', 'data', 'hook-manifest.json'), 'utf8'));

function copyIfNewer(src, dest) {
  let shouldCopy = !fs.existsSync(dest);
  if (!shouldCopy) {
    try {
      shouldCopy = fs.statSync(src).mtimeMs > fs.statSync(dest).mtimeMs;
    } catch (_) {
      shouldCopy = true;
    }
  }
  if (shouldCopy) fs.copyFileSync(src, dest);
  return shouldCopy;
}

function copyHookFile(hookSrc, hookDest) {
  const copied = copyIfNewer(hookSrc, hookDest);
  if (copied) fs.chmodSync(hookDest, 0o755);
  return copied;
}

// Top-level files of one hooks/ subdirectory (lib/ helpers the hooks shell out
// to, data/ vocabularies they read); subdirectories are not copied.
function copyHookSubdir(name, userHooksDir) {
  const srcDir  = path.join(packageDir, 'hooks', name);
  const destDir = path.join(userHooksDir, name);
  if (!fs.existsSync(srcDir)) return 0;
  fs.mkdirSync(destDir, { recursive: true });
  let copied = 0;
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    if (entry.isFile() && copyIfNewer(path.join(srcDir, entry.name), path.join(destDir, entry.name))) copied++;
  }
  return copied;
}

function registerHookInSettings(settings, entry, hookDest) {
  const { event, matcher, timeout, async: isAsync } = entry;

  settings.hooks = settings.hooks || {};
  settings.hooks[event] = settings.hooks[event] || [];

  // Find an existing matcher group for this {event, matcher} pair. matcher may
  // be null (e.g. SubagentStop has no matcher) — match nullish-to-nullish.
  let group = settings.hooks[event].find(g => g && (g.matcher || null) === (matcher || null));
  if (!group) {
    group = matcher ? { matcher, hooks: [] } : { hooks: [] };
    settings.hooks[event].push(group);
  }
  group.hooks = group.hooks || [];

  const alreadyRegistered = group.hooks.some(h =>
    h && h.type === 'command' && h.command === hookDest
  );
  if (alreadyRegistered) {
    return false;
  }

  const hookEntry = { type: 'command', command: hookDest };
  if (typeof timeout === 'number') hookEntry.timeout = timeout;
  if (isAsync === true) hookEntry.async = true;
  group.hooks.push(hookEntry);
  return true;
}

// Drop settings.json registrations that point into our own hooks dir at a
// retired hook or at a script no longer on disk — the latter is what produces
// the "/bin/sh: …: No such file or directory" non-blocking failures. Third-
// party hooks are preserved; matcher groups left empty are dropped. Returns
// whether anything was removed.
function pruneDanglingRegistrations(settings, userHooksDir) {
  if (!settings || !settings.hooks || typeof settings.hooks !== 'object') return false;
  const legacySet = new Set(manifest.legacyEiHooks);
  let modified = false;
  for (const event of Object.keys(settings.hooks)) {
    const groups = settings.hooks[event];
    if (!Array.isArray(groups)) continue;
    const keptGroups = [];
    for (const group of groups) {
      if (!group || !Array.isArray(group.hooks)) { keptGroups.push(group); continue; }
      const before = group.hooks.length;
      group.hooks = group.hooks.filter(h => {
        if (!h || h.type !== 'command' || typeof h.command !== 'string') return true;
        // A bare leading path is ours, `node "…"` / third-party commands are not.
        const scriptPath = h.command.trim().split(/\s+/)[0].replace(/^["']|["']$/g, '');
        if (!scriptPath.startsWith(userHooksDir + path.sep)) return true;
        return !legacySet.has(path.basename(scriptPath)) && fs.existsSync(scriptPath);
      });
      if (group.hooks.length !== before) modified = true;
      if (group.hooks.length === 0) { modified = true; continue; }
      keptGroups.push(group);
    }
    settings.hooks[event] = keptGroups;
  }
  return modified;
}

// claudeDir — the .claude/ base the harness installs into. Defaults to the
// user-level ~/.claude for require()-callers (scripts/sync-hooks.js, tests);
// the postinstall runner passes harnessClaudeDir so a local (non--g) install
// lands in <project>/.claude and a global (-g) install in ~/.claude.
function installCivitasHooks(claudeDir) {
  if (process.env.CIVITAS_SKIP_HOOK_INSTALL === '1') {
    console.log('[civitas-cerebrum] CIVITAS_SKIP_HOOK_INSTALL=1 — harness hook install skipped.');
    return;
  }

  const baseDir = claudeDir || userClaudeDir;
  const userHooksDir = path.join(baseDir, 'hooks');
  const settingsPath = path.join(baseDir, 'settings.json');
  fs.mkdirSync(userHooksDir, { recursive: true });

  // Load current settings.json (or {} if missing). Bail out preserving the
  // file on parse error — never overwrite malformed user config.
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    try {
      const raw = fs.readFileSync(settingsPath, 'utf8').trim();
      settings = raw ? JSON.parse(raw) : {};
    } catch (err) {
      console.warn(`[civitas-cerebrum] Could not parse ${settingsPath} — leaving it untouched. (${err.message})`);
      return;
    }
  }

  let copiedCount = 0;
  let registeredCount = 0;

  for (const entry of manifest.hooks) {
    const hookSrc = path.join(packageDir, 'hooks', entry.file);
    // Bundled hook missing — skip; don't fail the consumer's npm install.
    if (!fs.existsSync(hookSrc)) continue;
    const hookDest = path.join(userHooksDir, entry.file);
    if (copyHookFile(hookSrc, hookDest)) copiedCount++;
    if (registerHookInSettings(settings, entry, hookDest)) registeredCount++;
  }

  for (const file of manifest.companions) {
    const src = path.join(packageDir, 'hooks', file);
    if (!fs.existsSync(src)) continue;
    if (copyHookFile(src, path.join(userHooksDir, file))) copiedCount++;
  }

  // Without data/, installed hooks fall back to their hardcoded vocabularies
  // and silently drift from the repo's canonical data.
  copiedCount += copyHookSubdir('lib', userHooksDir);
  copiedCount += copyHookSubdir('data', userHooksDir);

  const pruned = pruneDanglingRegistrations(settings, userHooksDir);
  if (registeredCount > 0 || pruned) {
    fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  }

  pruneRetiredHooks(userHooksDir);

  console.log(`[civitas-cerebrum] Harness hooks (${baseDir === userClaudeDir ? 'system-wide' : 'this project only'}): ${copiedCount} script${copiedCount === 1 ? '' : 's'} copied to ${userHooksDir}, ${registeredCount} registration${registeredCount === 1 ? '' : 's'} added to ${settingsPath} (others already present). Restart Claude Code to pick them up.`);
}

function pruneRetiredHooks(homeHooksDir) {
  for (const name of manifest.legacyEiHooks) {
    const p = path.join(homeHooksDir, name);
    try {
      fs.unlinkSync(p);
      console.log('[ei-postinstall] pruned retired hook:', name);
    } catch (e) {
      if (e.code !== 'ENOENT') {
        console.warn('[ei-postinstall] could not prune', name + ':', e.message);
      }
    }
  }
}

module.exports = { installCivitasHooks };
