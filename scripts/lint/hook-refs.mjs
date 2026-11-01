import { existsSync, readFileSync } from 'node:fs';
import { ADAPTER_DIR, walk } from './util.mjs';

// Check 5 — adapter code cites resolvable methodology paths.
// Every `skills/….md` or `schemas/….json` path that appears in the adapter's
// sources (deny and advice messages end with a References: block of such
// paths) must exist, so a skill rename cannot orphan a hook's pointer. When
// claude-code/ is absent this checkout predates the adapter slice: pass with
// a note.
export function run(report) {
  if (!existsSync(ADAPTER_DIR)) {
    report('adapter References: paths resolve (claude-code/ absent in this checkout; written by the adapter slice)', true, []);
    return;
  }
  const detail = [];
  const sources = walk(ADAPTER_DIR, (p) => /\.(ts|js|mjs|cjs|json|md)$/.test(p) && !p.includes('/node_modules/') && !p.includes('/tests/'));
  let cited = 0;
  for (const f of sources) {
    const text = readFileSync(f, 'utf8');
    for (const path of new Set([...text.matchAll(/(?<![A-Za-z0-9._/-])(?:skills|schemas|docs)\/[A-Za-z0-9._/-]+\.(?:md|json)/g)].map((m) => m[0]))) {
      cited++;
      if (!existsSync(path)) detail.push(`${f}: cited path does not resolve: ${path}`);
    }
  }
  report(`adapter References: paths resolve (${sources.length} files, ${cited} cited paths)`, detail.length === 0, detail);
}
