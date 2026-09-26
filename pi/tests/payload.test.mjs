import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { claudeToolName, claudeToolInput, claudeToolResponse, contentText } from '../extensions/achilles/payload.ts';

test('names translate; custom names pass through', () => {
  assert.equal(claudeToolName('bash'), 'Bash');
  assert.equal(claudeToolName('find'), 'Glob');
  assert.equal(claudeToolName('ls'), 'ls');
  assert.equal(claudeToolName('Agent'), 'Agent');
  assert.equal(claudeToolName('mcp__jira__create'), 'mcp__jira__create');
});
test('read/write inputs', () => {
  assert.deepEqual(claudeToolInput('read', { path: 'a.md', offset: 2 }), { file_path: 'a.md', offset: 2 });
  assert.deepEqual(claudeToolInput('write', { path: 'a.md', content: 'x' }), { file_path: 'a.md', content: 'x' });
});
test('edit with one edit', () => {
  assert.deepEqual(claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] }),
    { file_path: 'a.md', old_string: 'o', new_string: 'n' });
});
test('edit with multiple edits becomes one whole-file Edit against the current file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'payload-'));
  try {
    fs.writeFileSync(path.join(dir, 'a.md'), 'alpha o1 beta o2 gamma');
    const r = claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o2', newText: 'n2' }, { oldText: 'o1', newText: 'n1' }] }, dir);
    assert.deepEqual(r, { file_path: 'a.md', old_string: 'alpha o1 beta o2 gamma', new_string: 'alpha n1 beta n2 gamma' });
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
  assert.deepEqual(claudeToolResponse('write', { path: 'a.md' }, c, false), { filePath: 'a.md', success: true });
  assert.deepEqual(claudeToolResponse('Agent', {}, c, true), { content: 'out', output: 'out', isError: true });
  assert.equal(contentText([{ type: 'text', text: 'a' }, { type: 'image' }, { type: 'text', text: 'b' }]), 'a\nb');
});
