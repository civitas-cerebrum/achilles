import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const SKILLS_DIR = 'skills';
export const ORCHESTRATOR_SKILL = 'skills/achilles-orchestrator/SKILL.md';
export const HARNESS_DOC = 'docs/harness/claude-code.md';
export const ADAPTER_DIR = 'claude-code';
export const AGENTS_DIR = 'agents';

// The five hand-authored agents (agents/achilles-<role>.md). The lints read the
// names from here so the methodology can be checked before those files land,
// and tolerate their absence with an explicit message rather than a crash.
export const AGENT_ROLES = ['achilles-orchestrator', 'achilles-inspector', 'achilles-author', 'achilles-reviewer', 'achilles-doc-writer'];
export const ROLE_WORDS = AGENT_ROLES.map((a) => a.replace(/^achilles-/, ''));

// Check modules take this `report` and call it once per finding group.
export function makeReport() {
  const state = { failed: false };
  function report(title, ok, details) {
    console.log(`[${ok ? 'PASS' : 'FAIL'}] ${title}`);
    if (ok) return;
    state.failed = true;
    for (const line of details) console.log(`        ${line}`);
  }
  return { report, state };
}

// Recursively collect files under `root` matching a predicate; an absent root is empty.
export function walk(root, pred, acc = []) {
  if (!existsSync(root)) return acc;
  for (const name of readdirSync(root)) {
    const full = join(root, name);
    if (statSync(full).isDirectory()) walk(full, pred, acc);
    else if (pred(full)) acc.push(full);
  }
  return acc;
}

export function skillDirs() {
  return readdirSync(SKILLS_DIR).filter((n) => {
    try { return statSync(join(SKILLS_DIR, n)).isDirectory(); } catch { return false; }
  });
}

// `description:` from a SKILL.md frontmatter as harnesses read it (a folded `>` or
// literal `|` block joined, quotes off), or null.
export function frontmatterDescription(file) {
  const fm = readFileSync(file, 'utf8').match(/^---\n([\s\S]*?)\n---/);
  if (!fm) return null;
  const lines = fm[1].split('\n');
  const i = lines.findIndex((l) => /^description:/.test(l));
  if (i < 0) return null;
  const head = lines[i].replace(/^description:\s*/, '');
  if (!/^[>|][+-]?$/.test(head)) return head.trim().replace(/^(["'])(.*)\1$/, '$2');
  const body = [];
  for (const l of lines.slice(i + 1)) { if (/^\S/.test(l)) break; body.push(l.trim()); }
  return (head.startsWith('>') ? body.filter(Boolean).join(' ') : body.join('\n')).trim();
}

// `name:` from a SKILL.md frontmatter, or null.
export function frontmatterName(file) {
  const m = readFileSync(file, 'utf8').match(/^---\n[\s\S]*?^name:\s*([^\n]+)$/m);
  return m ? m[1].trim() : null;
}
