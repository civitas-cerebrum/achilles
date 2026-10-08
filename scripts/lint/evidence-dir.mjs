import { readFileSync } from 'node:fs';

const FACTORY_SCHEMA = 'hooks/data/factory-rules.schema.json';
const EVIDENCE_GATE = 'hooks/factory/repository-evidence-gate.sh';
const EVIDENCE_NOTE = 'bin/evidence-note.mjs';
const DOCS = [
  'skills/achilles-protocol/references/factory-gates.md',
  'skills/achilles-protocol/references/selector-evidence.md',
];

// Check 14 — the selectors.evidence `evidenceDir` default agrees everywhere
// The field is optional, so its default decides where the gate looks and the
// CLI writes; if they disagree the gate denies a note the CLI just wrote. The
// schema's `default` is authoritative; the gate, the CLI and both reference
// pages restate it.
export function run(report) {
  const title = 'selectors.evidence evidenceDir default agrees across gate, tool and docs';
  const detail = [];
  const schema = JSON.parse(readFileSync(FACTORY_SCHEMA, 'utf8'));
  const want = schema?.$defs?.selectorsEvidence?.properties?.evidenceDir?.default;
  if (typeof want !== 'string' || !want) {
    report(title, false, [`${FACTORY_SCHEMA}: $defs.selectorsEvidence.properties.evidenceDir has no string "default"`]);
    return;
  }

  const gate = readFileSync(EVIDENCE_GATE, 'utf8').match(/EVDIR="\$\{EVDIR:-([^}"]+)\}"/);
  if (!gate) detail.push(`${EVIDENCE_GATE}: no \`EVDIR="\${EVDIR:-…}"\` fallback found`);
  else if (gate[1] !== want) detail.push(`${EVIDENCE_GATE}: falls back to "${gate[1]}", schema default is "${want}"`);

  const note = readFileSync(EVIDENCE_NOTE, 'utf8').match(/export const DEFAULT_EVIDENCE_DIR = '([^']+)'/);
  if (!note) detail.push(`${EVIDENCE_NOTE}: no \`export const DEFAULT_EVIDENCE_DIR\` found`);
  else if (note[1] !== want) detail.push(`${EVIDENCE_NOTE}: DEFAULT_EVIDENCE_DIR is "${note[1]}", schema default is "${want}"`);

  for (const doc of DOCS) {
    const md = readFileSync(doc, 'utf8');
    if (!md.includes(want)) detail.push(`${doc}: never names the default evidence dir "${want}"`);
    for (const m of md.matchAll(/[Dd]efault[^\n.]{0,24}`([A-Za-z0-9._/-]*evidence\/selectors)`/g)) {
      if (m[1] !== want) detail.push(`${doc}: documents the default as "${m[1]}", schema default is "${want}"`);
    }
  }

  report(`${title} ("${want}", 5 declarations)`, detail.length === 0, detail);
}
