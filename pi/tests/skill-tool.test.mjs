import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { registerSkillTool } from '../extensions/achilles/skill-tool.ts';
const fx = path.join(import.meta.dirname, 'fixtures', 'skills');
function tool() { const pi = makeFakePi(); registerSkillTool(pi, { roots: [fx] }); return pi.tools.find((t) => t.name === 'Skill'); }

test('registers as Skill with skill/args params', () => {
  const t = tool(); assert.equal(t.label, 'Skill'); assert.ok(t.parameters.properties.skill); assert.ok(t.parameters.properties.args);
});
test('orchestrator skill returns the body wrapped with its path', async () => {
  const r = await tool().execute('c1', { skill: 'orch-skill', args: 'go' }, undefined, undefined, makeFakeCtx());
  assert.match(r.content[0].text, /<skill name="orch-skill" path="[^"]*orch-skill\/SKILL\.md">/);
  assert.match(r.content[0].text, /Body of orch skill/); assert.match(r.content[0].text, /User request: go/);
  assert.equal(r.details.refused, undefined);
});
test('subagent-only by flag refuses with a delegate instruction', async () => {
  const r = await tool().execute('c2', { skill: 'sub-flag' }, undefined, undefined, makeFakeCtx());
  assert.doesNotMatch(r.content[0].text, /Secret body/);
  assert.match(r.content[0].text, /Delegate it: Agent \{ skill: "sub-flag"/);
  assert.equal(r.details.refused, true);
});
test('subagent-only by marker refuses too', async () => {
  const r = await tool().execute('c3', { skill: 'sub-marker' }, undefined, undefined, makeFakeCtx());
  assert.doesNotMatch(r.content[0].text, /Secret body/); assert.equal(r.details.refused, true);
});
test('unknown skill throws with the known names', async () => {
  await assert.rejects(() => tool().execute('c4', { skill: 'ghost' }, undefined, undefined, makeFakeCtx()), /Unknown skill "ghost".*orch-skill/s);
});
test('inside a subagent (depth >= 1) a subagent-only skill returns its body', async (t) => {
  const saved = process.env.ACHILLES_PI_DEPTH;
  t.after(() => { if (saved === undefined) delete process.env.ACHILLES_PI_DEPTH; else process.env.ACHILLES_PI_DEPTH = saved; });
  process.env.ACHILLES_PI_DEPTH = '1';
  const r = await tool().execute('c5', { skill: 'sub-flag' }, undefined, undefined, makeFakeCtx());
  assert.match(r.content[0].text, /<skill name="sub-flag"/); assert.match(r.content[0].text, /Secret body/);
  assert.equal(r.details.refused, undefined);
});
