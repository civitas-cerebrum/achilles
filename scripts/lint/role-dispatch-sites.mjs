import { readFileSync } from 'node:fs';
import { SKILLS_DIR, walk } from './util.mjs';

const QA_MANDATE = 'hooks/data/achilles-qa.kernel-mandate.json';

// Dispatch prefixes the kernel deliberately leaves unbound (the mandate's
// unboundAgentPolicy covers them): methodology workers with no role of their own.
const UNBOUND_PREFIXES = ['repair-worker', 'composition-judge', 'selector-development'];
// Exact spellings only: legacy composer forms (KERNEL_MANDATE=0 sessions) and the
// journey-slug progress-log lines (`j-<slug>: …`).
const UNBOUND_EXACT = ['composer', 'composer-j', 'composer-sj', 'j', 'sj'];

// Roles that existed in earlier manifests; prose naming them as a role is stale.
// `batch-reviewer` still names the cycle-1 reviewer mode in coverage-expansion, so
// only its backticked spelling counts; the others are caught as bare words too
// (a path or `.js` suffix, as in hooks/lib/selector-diff-validator.js, is not a role).
const RETIRED_ROLES = ['batch-reviewer', 'in-flight-composer', 'selector-diff-validator'];
const BACKTICK_ONLY = ['batch-reviewer'];

// Check 12 — role names in prose ↔ QA mandate roles
// Prose surfaces: skills/**/*.md (the vendored mandate-designer excluded) and README.md.
// Three shapes are read: `subagent_type: <role>`, a backticked dispatch prefix
// (`<role>[-word]<placeholder>…:`, e.g. `<role>-phase<N>:`; grammar in
// hooks/lib/dispatch-prefix.sh), and any retired role name. Each named role must exist in the mandate, and
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
      // A dispatch prefix is colon-terminated with a placeholder; the text before the
      // first placeholder must start with a role. Colon-less placeholder tokens (CLI
      // slugs) only credit a role; a bare `<role>-` credits one only on a "dispatch" line.
      for (const m of line.matchAll(/`([a-z][a-z0-9-]*)<[^`\s]*`(:?)/g)) {
        const name = m[1].replace(/-$/, '');
        const role = roleOf(name);
        if (!m[2] && !m[0].includes(':')) { if (role) dispatched.add(role); continue; } // CLI slug
        if (role) dispatched.add(role);
        else if (!UNBOUND_EXACT.includes(name) && !UNBOUND_PREFIXES.some((p) => name === p || name.startsWith(`${p}-`))) detail.push(`${at}: dispatch prefix "${name}-…:" names no mandate role`);
      }
      if (/dispatch/i.test(line)) {
        for (const m of line.matchAll(/`([a-z][a-z0-9-]*)-`/g)) if (known.has(m[1])) dispatched.add(m[1]);
      }
      for (const r of RETIRED_ROLES) {
        if ((BACKTICK_ONLY.includes(r) ? line.includes(`\`${r}\``) : new RegExp(`(?<![\\w/.-])${r}(?![\\w.-])`).test(line))) detail.push(`${at}: "${r}" is a retired role`);
      }
    });
  }

  for (const r of roles) {
    if (r !== main && !dispatched.has(r)) detail.push(`mandate role "${r}" is dispatched nowhere in skills/ or README.md`);
  }

  report(`role names in prose ↔ QA mandate roles (${roles.length} roles, ${files.length} files)`,
    detail.length === 0, detail);
}
