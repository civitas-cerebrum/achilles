import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export interface SkillInfo {
  name: string;
  dir: string;
  file: string;
  description: string;
  body: string;
  subagentOnly: boolean;
}

/** <package>/ is three levels above this file: pi/extensions/achilles/. fileURLToPath rather than
 * import.meta.dirname so the module resolves the same under pi's jiti loader and under node --test. */
export const PACKAGE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

export function skillRoots(home: string): string[] {
  return [path.join(home, '.agents', 'skills'), path.join(PACKAGE_DIR, 'skills')];
}

function parseFrontmatter(text: string): { fm: Record<string, string>; body: string } {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fm: {}, body: text };
  const fm: Record<string, string> = {};
  let key = '';
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (kv) { key = kv[1]; fm[key] = kv[2].trim(); }
    else if (key && /^\s+\S/.test(line)) fm[key] += ' ' + line.trim();
  }
  return { fm, body: m[2] };
}

/** Truthy YAML-ish flag: "true" or "yes", case-insensitive. */
function isFlagTrue(value: string | undefined): boolean {
  return /^(true|yes)$/i.test(value ?? '');
}

/**
 * A description is a YAML folded (`>`) scalar in most skills, so parseFrontmatter's naive
 * key: value capture leaves the fold indicator (">") as a leading token before the first
 * continuation line is appended. The subagent-only marker can be bold ("**Subagent-only.**",
 * e.g. failure-diagnosis, contributing-to-achilles-protocol) or plain text ("Subagent-only
 * skill.", e.g. workflow-reviewer) — both only ever appear at the very start of the folded
 * description. Anchoring on that start (past an optional fold indicator and optional bold
 * markers) classifies all three real subagent-only skills without false-positiving on skills
 * that merely mention "subagent-only" mid-description (e.g. achilles-protocol, describing
 * failure-diagnosis).
 */
const SUBAGENT_ONLY_MARKER = /^>?\s*\*{0,2}Subagent-only\b/i;

const SKILL_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

/** Sorted, de-duplicated names of skills (directories holding a SKILL.md) across all roots.
 * Mirrors resolveSkill's guarded-failure discipline: an unreadable root, a root that doesn't
 * exist, or a root that is a regular file must not throw — they are simply skipped. */
export function listSkills(roots: string[]): string[] {
  const names = new Set<string>();
  for (const root of roots) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(root, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const d of entries) {
      if (!d.isDirectory() || !SKILL_NAME_RE.test(d.name)) continue;
      try {
        if (fs.existsSync(path.join(root, d.name, 'SKILL.md'))) names.add(d.name);
      } catch {
        continue;
      }
    }
  }
  return [...names].sort();
}

export function resolveSkill(name: string, roots: string[]): SkillInfo | undefined {
  if (!SKILL_NAME_RE.test(name)) return undefined;
  for (const root of roots) {
    const dir = path.join(root, name);
    const file = path.join(dir, 'SKILL.md');
    let text: string;
    try {
      // existsSync + readFileSync as one guarded step: a permission error, a TOCTOU race, or
      // SKILL.md being a directory rather than a file must not throw out of resolveSkill — it
      // would otherwise propagate through steer()'s String.replace callback and crash the
      // whole message rewrite. Treat any failure here as "unresolved in this root".
      if (!fs.existsSync(file)) continue;
      text = fs.readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const { fm, body } = parseFrontmatter(text);
    const description = fm.description ?? '';
    const subagentOnly =
      isFlagTrue(fm['disable-model-invocation']) ||
      SUBAGENT_ONLY_MARKER.test(description);
    return { name, dir, file, description, body, subagentOnly };
  }
  return undefined;
}
