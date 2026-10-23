import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { SKILLS_DIR, AGENTS_DIR, AGENT_ROLES, ROLE_WORDS, walk } from './util.mjs';

// Roles from the retired 23-role manifest. Prose that still names one of these
// as a role (backticked, or as a `<role>-<slug>:` dispatch prefix) is stale.
const RETIRED_ROLES = ['scaffolder', 'phase-validator', 'process-validator', 'perf-reviewer', 'task-reviewer',
  'verifier', 'live-inspector', 'doc-author', 'implementer', 'contribution-handover', 'workflow-reviewer',
  'batch-reviewer', 'in-flight-composer', 'repair-worker', 'phase1', 'phase2', 'phase4', 'stage2', 'fd'];
// Session-slug families and spill-file names legitimately start with some of
// these tokens; only the role-grammar shapes below count.
const PREFIX_GRAMMAR = /`([a-z][a-z0-9-]*)-<[^`>]+>:`/g;      // `<role>-<slug>:` dispatch prefix
const SUBAGENT_TYPE = /subagent_type[:=]/g;
const KERNEL_TAG = /<<kernel-mandate-role/g;

// Check 12 — role names in prose ↔ the five agents.
// Dispatch is the Agent tool with one of the five `achilles-<role>` types (prose
// may say "the inspector" for the role); prose must not carry the retired dispatch-prefix grammar, a
// `subagent_type`, a kernel tag, or a retired role name as a role. Each of the
// four expert roles must be dispatched from at least one workflow. The agent
// files themselves are written by the adapter slice; their absence is reported
// as a note, not a failure.
export function run(report) {
  const detail = [];
  const files = [...walk(SKILLS_DIR, (f) => f.endsWith('.md')), ...walk('docs/harness', (f) => f.endsWith('.md'))];
  const dispatched = new Set();

  for (const file of files) {
    const lines = readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      const at = `${file}:${i + 1}`;
      if (SUBAGENT_TYPE.test(line)) detail.push(`${at}: subagent_type is adapter vocabulary; dispatch by role`);
      if (KERNEL_TAG.test(line)) detail.push(`${at}: kernel tag; the role kernel is gone`);
      SUBAGENT_TYPE.lastIndex = 0; KERNEL_TAG.lastIndex = 0;
      for (const m of line.matchAll(PREFIX_GRAMMAR)) detail.push(`${at}: dispatch-prefix grammar "${m[0]}"; name the role instead`);
      for (const r of RETIRED_ROLES) {
        if (line.includes('`' + r + '`') && /\b(role|agent|dispatch)/i.test(line)) detail.push(`${at}: "${r}" is a retired role`);
      }
      if (/dispatch/i.test(line)) {
        for (const word of ROLE_WORDS) {
          if (new RegExp(`\\b(?:achilles-)?${word}\\b`).test(line)) dispatched.add(`achilles-${word}`);
        }
      }
    });
  }

  for (const r of AGENT_ROLES) {
    if (r !== 'achilles-orchestrator' && !dispatched.has(r)) detail.push(`role "${r}" is dispatched nowhere in skills/ or docs/harness/`);
  }

  const notes = [];
  for (const r of AGENT_ROLES) {
    const f = join(AGENTS_DIR, `${r}.md`);
    if (!existsSync(f)) notes.push(`note: ${f} is absent in this checkout (written by the adapter slice); role name checked from util.mjs`);
  }
  for (const n of notes) console.log(`        ${n}`);

  report(`role names in prose ↔ the five agents (${AGENT_ROLES.length} roles, ${files.length} files)`, detail.length === 0, detail);
}
