import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_EVIDENCE_DIR, NOTE_REFUSED, validateNote } from '../../bin/lib/evidence-note.mjs';
import { CASES } from '../../claude-code/tests/factory-cases.mjs';

const note = (over = {}) => ({ key: 'Login.submit', selector: 'button[type=submit]', source: 'tool', context: 'region-1', ...over });

test('an @ in the selector is allowed', () => {
  assert.match(validateNote(note({ selector: 'a[href^="mailto:x@y"]' })), /^- selector:/m);
});

test('an @ elsewhere is refused', () => {
  assert.throws(() => validateNote(note({ context: 'x@y.example' })), (e) => e.code === NOTE_REFUSED);
});

test('a note without a source is refused', () => {
  assert.throws(() => validateNote(note({ source: '' })), (e) => e.code === NOTE_REFUSED);
});

test('the tool default is the directory the gate reads when evidenceDir is omitted', () => {
  const gateCase = CASES.find((c) => c.name === 'repository-evidence-gate.allow-default-evidence-dir');
  assert.ok(Object.keys(gateCase.write).includes(`${DEFAULT_EVIDENCE_DIR}/HomePage.zzDefault.md`));
});
