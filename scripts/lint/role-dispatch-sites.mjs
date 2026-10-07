import { readFileSync } from 'node:fs';
import { SKILLS_DIR, walk } from './util.mjs';

const QA_MANDATE = 'hooks/data/achilles-qa.kernel-mandate.json';

// Dispatch prefixes the kernel deliberately leaves unbound (the mandate's
// unboundAgentPolicy covers them): methodology workers with no role of their own.
// `composer`, `j` and `sj` are spellings the docs name only to say they are refused.
const UNBOUND_PREFIXES = ['repair-worker', 'composition-judge', 'selector-development', 'composer', 'j', 'sj'];

// Roles that existed in earlier manifests; prose naming them as a role is stale.
const RETIRED_ROLES = ['batch-reviewer', 'in-flight-composer', 'selector-diff-validator'];

// Check 12 — role names in prose ↔ QA mandate roles
// Prose surfaces: skills/**/*.md (the vendored mandate-designer excluded) and README.md.
// Three shapes are read: `subagent_type: <role>`, a backticked dispatch prefix
// (`<role>-<placeholder>…:`, grammar in hooks/lib/dispatch-prefix.sh), and any
// backticked retired role name. Each named role must exist in the mandate, and
// every subagent role must be dispatched from at least one skill.
export function run(report) {
  const mandate = JSON.parse(readFileSync(QA_MANDATE, 'utf8'));
  const main = mandate.settings?.mainSessionRole;
  const roles = Object.keys(mandate.roles ?? {});
  const known = new Set(roles);

  const files = [
    ...walk(SKILLS_DIR, (f) => f.endsWith('.md') && !f.split('/').includes('mandate-designer')),
    'README.md',
  ];

  const detail = [];
  const dispatched = new Set();
  const roleOf = (name) => roles.filter((r) => name === r || name.startsWith(`${r}-`))
    .sort((a, b) => b.length - a.length)[0];

  for (const file of files) {
    const lines = readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      const at = `${file}:${i + 1}`;
      for (const m of line.matchAll(/subagent_type[:=]\s*["'`]?([a-z][a-z0-9-]*)/g)) {
        if (!known.has(m[1])) detail.push(`${at}: subagent_type "${m[1]}" is not a mandate role`);
        else dispatched.add(m[1]);
      }
      // Colon-terminated prefix: must name a role. Bare `<role>-<slug>` (the
      // playwright-cli slug table) and `<role>-` only count as a dispatch site.
      for (const m of line.matchAll(/`([a-z][a-z0-9-]*?)-(?:<[^`>]*>[^`]*|)`(:?)/g)) {
        const name = m[1];
        const role = roleOf(name);
        if (role) dispatched.add(role);
        else if (!m[0].includes(':') && !m[2]) continue;
        else if (!UNBOUND_PREFIXES.some((p) => name === p || name.startsWith(`${p}-`))) detail.push(`${at}: dispatch prefix "${name}-…:" names no mandate role`);
      }
      for (const r of RETIRED_ROLES) {
        if (line.includes(`\`${r}\``)) detail.push(`${at}: "${r}" is a retired role`);
      }
    });
  }

  for (const r of roles) {
    if (r !== main && !dispatched.has(r)) detail.push(`mandate role "${r}" is dispatched nowhere in skills/ or README.md`);
  }

  report(`role names in prose ↔ QA mandate roles (${roles.length} roles, ${files.length} files)`,
    detail.length === 0, detail);
}
