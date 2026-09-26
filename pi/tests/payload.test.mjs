import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { claudeToolName, claudeToolInput, claudeToolResponse, contentText, wholeFileEdit } from '../extensions/achilles/payload.ts';
import { minimalSpan } from '../extensions/achilles/edit-match.ts';

test('names translate; custom names pass through', () => {
  assert.equal(claudeToolName('bash'), 'Bash');
  assert.equal(claudeToolName('find'), 'Glob');
  assert.equal(claudeToolName('ls'), 'ls');
  assert.equal(claudeToolName('Agent'), 'Agent');
  assert.equal(claudeToolName('mcp__jira__create'), 'mcp__jira__create');
});
test('read/write inputs', () => {
  assert.deepEqual(claudeToolInput('read', { path: 'a.md', offset: 2 }, '/w'), { file_path: '/w/a.md', offset: 2 });
  assert.deepEqual(claudeToolInput('write', { path: 'a.md', content: 'x' }, '/w'), { file_path: '/w/a.md', content: 'x' });
  // pi's path prefixes are resolved, so path-matched hooks see the file pi will touch.
  assert.equal(claudeToolInput('write', { path: '@tests/x.json', content: 'x' }, '/w').file_path, '/w/tests/x.json');
  assert.equal(claudeToolInput('read', { path: '~/x.md' }, '/w').file_path, path.join(os.homedir(), 'x.md'));
  assert.equal(claudeToolInput('read', { path: 'file:///abs/y.md' }, '/w').file_path, '/abs/y.md');
  assert.equal(claudeToolInput('edit', { path: '@a.md', edits: [{ oldText: 'o', newText: 'n' }, { oldText: 'p', newText: 'q' }] }, '/w').file_path, '/w/a.md');
});
test('edit with one edit', () => {
  assert.deepEqual(claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] }, '/w'),
    { file_path: '/w/a.md', old_string: 'o', new_string: 'n' });
});
test('edit with multiple edits becomes one Edit of the changed span of the current file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'payload-'));
  try {
    fs.writeFileSync(path.join(dir, 'a.md'), 'alpha o1 beta o2 gamma');
    const r = claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o2', newText: 'n2' }, { oldText: 'o1', newText: 'n1' }] }, dir);
    assert.deepEqual(r, { file_path: path.join(dir, 'a.md'), old_string: 'alpha o1 beta o2 gamma', new_string: 'alpha n1 beta n2 gamma' });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('multi-edit falls back to joined strings when an edit cannot apply', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'payload-'));
  try {
    fs.writeFileSync(path.join(dir, 'a.md'), 'x o1 o1 y');
    const r = claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o1', newText: 'n1' }, { oldText: 'zz', newText: 'n2' }] }, dir);
    assert.equal(r.old_string, 'o1\nzz');
    assert.equal(r.new_string, 'n1\nn2');
    const missing = claudeToolInput('edit', { path: 'nope.md', edits: [{ oldText: 'a', newText: 'b' }, { oldText: 'c', newText: 'd' }] }, dir);
    assert.equal(missing.old_string, 'a\nc');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('bash and other inputs pass through', () => {
  assert.deepEqual(claudeToolInput('bash', { command: 'ls' }), { command: 'ls' });
  assert.deepEqual(claudeToolInput('Agent', { description: 'd', prompt: 'p' }), { description: 'd', prompt: 'p' });
});
test('responses', () => {
  const c = [{ type: 'text', text: 'out' }];
  assert.deepEqual(claudeToolResponse('bash', {}, c, false), { stdout: 'out', stderr: '', interrupted: false });
  assert.deepEqual(claudeToolResponse('write', { path: '@a.md' }, c, false, undefined, '/w'), { filePath: '/w/a.md', success: true });
  assert.deepEqual(claudeToolResponse('Agent', {}, c, true), { content: 'out', output: 'out', isError: true });
  assert.equal(contentText([{ type: 'text', text: 'a' }, { type: 'image' }, { type: 'text', text: 'b' }]), 'a\nb');
});

// pi's edit semantics (edit-match.ts): each case writes `file` into a temp dir and translates `edits`.
function translate(content, edits, p = 'f.txt') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'payload-'));
  try {
    if (content !== undefined) fs.writeFileSync(path.join(dir, 'f.txt'), content);
    const r = claudeToolInput('edit', { path: p, edits }, dir);
    // file_path is absolute (resolved against the cwd); compare it relative to the temp dir.
    assert.ok(path.isAbsolute(r.file_path));
    r.file_path = path.relative(dir, r.file_path);
    return { r, exact: wholeFileEdit(p, edits.map((e) => ({ old_string: e.oldText, new_string: e.newText })), dir) };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
test('pi rejects a duplicate oldText: no translation, joined fallback', () => {
  const { r, exact } = translate('x o1 o1 y\nz\n', [{ oldText: 'o1', newText: 'n1' }, { oldText: 'z', newText: 'Z' }]);
  assert.equal(exact, undefined);
  assert.equal(r.old_string, 'o1\nz');
});
test('pi rejects overlapping edits (abc + bcd)', () => {
  assert.equal(translate('xabcdx\n', [{ oldText: 'abc', newText: 'A' }, { oldText: 'bcd', newText: 'B' }]).exact, undefined);
});
test('pi rejects an empty oldText', () => {
  assert.equal(translate('abc\n', [{ oldText: '', newText: 'A' }, { oldText: 'c', newText: 'C' }]).exact, undefined);
  assert.equal(translate('abc\n', [{ oldText: '', newText: 'A' }]).exact, undefined);
});
test('a missing file: no translation, the model text passes through', () => {
  const { r, exact } = translate(undefined, [{ oldText: 'a', newText: 'b' }, { oldText: 'c', newText: 'd' }]);
  assert.equal(exact, undefined);
  assert.equal(r.old_string, 'a\nc');
  assert.deepEqual(translate(undefined, [{ oldText: 'a', newText: 'b' }]).r, { file_path: 'f.txt', old_string: 'a', new_string: 'b' });
});
test('a no-op edit is rejected like pi rejects it', () => {
  assert.equal(translate('k1 k2\n', [{ oldText: 'k1', newText: 'k1' }, { oldText: 'k2', newText: 'k2' }]).exact, undefined);
  assert.equal(translate('k1 k2\n', [{ oldText: 'k1', newText: 'k1' }]).exact, undefined);
});
test('CRLF file with a multi-line oldText: old_string matches the raw bytes, new_string keeps CRLF', () => {
  const file = 'a\r\nb\r\nc\r\nd\r\n';
  const { r } = translate(file, [{ oldText: 'a\nb', newText: 'A\nB' }, { oldText: 'd', newText: 'D' }]);
  assert.deepEqual(r, { file_path: 'f.txt', old_string: 'a\r\nb\r\nc\r\nd\r', new_string: 'A\r\nB\r\nc\r\nD\r' });
  // Single edit, same rule.
  const one = translate(file, [{ oldText: 'b\nc', newText: 'B\nC' }]).r;
  assert.deepEqual(one, { file_path: 'f.txt', old_string: 'b\r\nc\r', new_string: 'B\r\nC\r' });
  assert.equal(file.split(one.old_string).length - 1, 1);
});
test('fuzzy matching: trailing whitespace and smart quotes', () => {
  const ws = translate('foo  \nbar\nbaz\n', [{ oldText: 'foo\nbar', newText: 'F' }, { oldText: 'baz', newText: 'Z' }]).r;
  assert.deepEqual(ws, { file_path: 'f.txt', old_string: 'foo  \nbar\nbaz', new_string: 'F\nZ' });
  const q = translate('keep\nsay “hi”\nkeep2\n', [{ oldText: 'say "hi"', newText: 'say "bye"' }]).r;
  assert.deepEqual(q, { file_path: 'f.txt', old_string: 'say “hi”', new_string: 'say "bye"' });
});
test('an @path resolves the way pi resolves it', () => {
  assert.deepEqual(translate('k1\nk2\n', [{ oldText: 'k1', newText: 'K1' }, { oldText: 'k2', newText: 'K2' }], '@f.txt').r,
    { file_path: 'f.txt', old_string: 'k1\nk2', new_string: 'K1\nK2' });
});
test('a BOM is preserved: inside the span when line 1 changes, outside it otherwise', () => {
  assert.deepEqual(translate('﻿k1\nmid\nk2\n', [{ oldText: 'k1', newText: 'K1' }, { oldText: 'k2', newText: 'K2' }]).r,
    { file_path: 'f.txt', old_string: '﻿k1\nmid\nk2', new_string: '﻿K1\nmid\nK2' });
  assert.deepEqual(translate('﻿top\nk1\nmid\nk2\nend\n', [{ oldText: 'k1', newText: 'K1' }, { oldText: 'k2', newText: 'K2' }]).r,
    { file_path: 'f.txt', old_string: 'k1\nmid\nk2', new_string: 'K1\nmid\nK2' });
});
test('the minimal span covers only the changed lines, widened until unique', () => {
  const file = 'head\nterm here\n{\n  "a": "o1",\n  "x": 1,\n  "b": "o2"\n}\ntail\n';
  const { r } = translate(file, [{ oldText: '"o1"', newText: '"n1"' }, { oldText: '"o2"', newText: '"n2"' }]);
  assert.deepEqual(r, { file_path: 'f.txt', old_string: '  "a": "o1",\n  "x": 1,\n  "b": "o2"', new_string: '  "a": "n1",\n  "x": 1,\n  "b": "n2"' });
  assert.ok(!r.new_string.includes('term'));
  // A changed line that repeats elsewhere is widened by whole lines until the span is unique.
  assert.deepEqual(minimalSpan('x\ndup\ny\ndup\nz\n', 'x\ndup\ny\nDUP\nz\n'), { old_string: 'y\ndup\nz', new_string: 'y\nDUP\nz' });
  // A pure line insertion still gets a non-empty, unique old_string.
  assert.deepEqual(minimalSpan('a\nb\n', 'a\nnew\nb\n'), { old_string: 'a\nb', new_string: 'a\nnew\nb' });
  // Hooks strip trailing newlines: a span unique only thanks to its final newline is widened until
  // its stripped form is unique ("pending" alone is a prefix of the "pending", line above; widening
  // takes a line on each side).
  assert.deepEqual(minimalSpan('  "s": "pending",\n  "s": "pending"\n}\n', '  "s": "pending",\n  "s": "done"\n}\n'),
    { old_string: '  "s": "pending",\n  "s": "pending"\n}', new_string: '  "s": "pending",\n  "s": "done"\n}' });
  // An added trailing blank line cannot survive stripping on its own, so the span takes the next line.
  assert.deepEqual(minimalSpan('a\nb\nc\n', 'a\nb\n\nc\n'), { old_string: 'b\nc', new_string: 'b\n\nc' });
  // Capped at the whole file.
  assert.deepEqual(minimalSpan('d\nd\n', 'd\nD\n'), { old_string: 'd\nd', new_string: 'd\nD' });
});
test('a single exact edit on an LF file passes through unchanged', () => {
  assert.deepEqual(translate('a\nfoo bar\nb\n', [{ oldText: 'foo', newText: 'baz' }]).r, { file_path: 'f.txt', old_string: 'foo', new_string: 'baz' });
});
