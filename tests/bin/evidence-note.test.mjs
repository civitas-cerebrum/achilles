import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateNote, NOTE_REFUSED } from '../../bin/lib/evidence-note.mjs';

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
