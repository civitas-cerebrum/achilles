import { test } from 'node:test';
import assert from 'node:assert/strict';
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
test('edit with multiple edits', () => {
  const r = claudeToolInput('edit', { path: 'a.md', edits: [{ oldText: 'o1', newText: 'n1' }, { oldText: 'o2', newText: 'n2' }] });
  assert.equal(r.file_path, 'a.md');
  assert.equal(r.old_string, 'o1\no2');
  assert.equal(r.new_string, 'n1\nn2');
  assert.deepEqual(r.edits, [{ old_string: 'o1', new_string: 'n1' }, { old_string: 'o2', new_string: 'n2' }]);
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
