import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

// Check 5 — hook runtime messages carry resolvable methodology References
// Convention: contributing-to-achilles-protocol/SKILL.md §"Hook error message
// format — repo standard". Every hook that can emit a user-facing decision at
// runtime (PreToolUse deny/ask, systemMessage warn, Stop decision:block, or a
// strict-mode exit-2 stderr block) must end those messages with a
// `References:` block of repo-relative canonical-rule paths. Mechanics of the
// check: full-line comments are stripped first, so the header's
// "Canonical reference" section can never satisfy it — the References must
// live in the message-producing region (strings, heredocs, echo lines).
// Every cited skills/….md or schemas/….json path (in any hook or hooks/lib/
// script, emitting or not) must resolve in the repo, so a skill rename cannot
// silently orphan a hook's pointers.
export function run(report) {
  const detail = [];
  const hooks = readdirSync('hooks')
    .filter((f) => f.endsWith('.sh'))
    .map((f) => join('hooks', f));
  // Sourced libs carry citations for the hooks that use them (the pipeline
  // gates' References and message refs live in hooks/lib/pipeline-gate.sh),
  // so their paths must resolve too. Libs do not emit on their own, so the
  // References requirement below applies to hook files only.
  const libs = readdirSync(join('hooks', 'lib'))
    .filter((f) => f.endsWith('.sh'))
    .map((f) => join('hooks', 'lib', f));
  const libSet = new Set(libs);

  let emitters = 0;
  let citedPaths = 0;

  for (const h of [...hooks, ...libs]) {
    const raw = readFileSync(h, 'utf8');
    // Strip full-line comments: the message-producing region is what remains.
    const code = raw
      .split('\n')
      .filter((l) => !/^\s*#/.test(l))
      .join('\n');

    const pathMatches = [...code.matchAll(/(?:skills|schemas)\/[A-Za-z0-9._/-]+\.(?:md|json)/g)].map((m) => m[0]);
    for (const cited of new Set(pathMatches)) {
      citedPaths++;
      if (!existsSync(cited)) {
        detail.push(`${h}: cited path does not resolve: ${cited}`);
      }
    }

    if (libSet.has(h)) continue;

    const emits = /permissionDecision|"decision"\s*:\s*"block"|systemMessage|^exit 2$/m.test(code);
    if (!emits) continue;
    emitters++;

    if (!/References:/.test(code)) {
      detail.push(`${h}: emits deny/warn/block but its runtime messages have no References: block`);
      continue;
    }
    if (pathMatches.length === 0) {
      detail.push(`${h}: emits deny/warn/block but cites no skills/ or schemas/ path in its runtime messages`);
    }
  }

  report(
    `hook runtime messages carry resolvable methodology References (${emitters} emitting hooks, ${citedPaths} cited paths)`,
    detail.length === 0,
    detail,
  );
}
