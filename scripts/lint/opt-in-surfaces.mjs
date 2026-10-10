import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { walk } from './util.mjs';

const OPT_IN_DOC = 'skills/achilles-protocol/references/opt-in-surfaces.md';
const KNOWN_LIMITS_DOC = 'skills/achilles-protocol/references/known-limits.md';

export function run(report) {
  const detail = [];
  const sources = [
    ...walk('hooks', (p) => /\.(sh|js|cjs|mjs)$/.test(p) && !p.includes('/tests/') && !/\.bundle\.m?js$/.test(p)),
    ...walk('scripts', (p) => /\.(js|mjs)$/.test(p)),
  ];
  // Operator-facing switch names: project prefixes plus the *_GATE/_GUARD/_OVERRIDE
  // suffixes the gates use. Ordinary environment is excluded by the deny-list.
  const switchShape = /^(ACHILLES_|CIVITAS_|KERNEL_MANDATE|FACTORY_|SPEND_|NO_SKIP_|SCHEMA_RETURN_GUARD|DECK_INSPECTION_GATE|FAKE_|DISABLE_|SKIP_)|(_GATE|_GUARD|_OVERRIDE)$/;
  const ordinaryEnv = /^(HOME|PATH|TMPDIR|CLAUDE_.*|XDG_.*|PLAYWRIGHT_(?!SKIP_).*|PWD|USER|SHELL|LANG)$/;
  const readShapes = [
    /\$\{([A-Z][A-Z0-9_]*):?[-=?+]/g, // ${NAME:-default}: a read with a default is how hooks consume env; bare $NAME is also a local
    /process\.env\.([A-Z][A-Z0-9_]*)/g,
    /process\.env\[['"]([A-Z][A-Z0-9_]*)['"]\]/g,
  ];
  const names = new Set();
  for (const f of sources) {
    const text = readFileSync(f, 'utf8');
    for (const re of readShapes)
      for (const m of text.matchAll(re)) if (switchShape.test(m[1]) && !ordinaryEnv.test(m[1])) names.add(m[1]);
    // A self-default, x="${x:-…}" in capitals, lets the environment replace the variable unless it was just set
    // (an assignment on that line or the three before it: a local given a default).
    for (const m of text.matchAll(/\b([A-Z][A-Z0-9_]*)="?\$\{\1:?-/g)) {
      const before = text.slice(0, m.index).split('\n').slice(-4).join('\n');
      if (!ordinaryEnv.test(m[1]) && !new RegExp(`(^|[^\\w])${m[1]}=`).test(before)) names.add(m[1]);
    }
  }
  const doc = existsSync(OPT_IN_DOC) ? readFileSync(OPT_IN_DOC, 'utf8') : '';
  const missing = [...names].filter((n) => !doc.includes('`' + n + '`')).sort();
  if (!doc) detail.push(`${OPT_IN_DOC} is missing`);
  if (missing.length) detail.push(`switches read in code with no row in ${OPT_IN_DOC}: ${missing.join(', ')}`);

  // Check 8b — a Detector cell naming a cases/NN-*.sh file must name a file that exists.
  const limits = existsSync(KNOWN_LIMITS_DOC) ? readFileSync(KNOWN_LIMITS_DOC, 'utf8') : '';
  if (!limits) detail.push(`${KNOWN_LIMITS_DOC} is missing`);
  for (const m of limits.matchAll(/`cases\/([\w.-]+\.sh)`/g))
    if (!existsSync(join('hooks/tests/cases', m[1]))) detail.push(`${KNOWN_LIMITS_DOC} names a missing detector: cases/${m[1]}`);

  report(`env switches read by hooks/scripts ↔ opt-in-surfaces.md; known-limits detectors exist (${names.size} switches read)`, detail.length === 0, detail);
}
