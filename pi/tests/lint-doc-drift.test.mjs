// Checks 7 and 8 of scripts/lint-doc-drift.mjs — the two conventions the pi adapter reads out of
// the methodology: a skill's `pi-kernel:` declaration, and the dispatch-role token a heading prints.
//
// It lives in the pi suite because the conventions are the pi adapter's and node:test is where this
// repo asserts node code; the lint itself runs in CI (.github/workflows/ci.yml) and at prepack, which
// is where a methodology author meets it. Each RED case is a fixture tree that fails the check before
// the fix existed and names the skill, the entry/heading and the convention in its message.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { checkPiKernelEntries, checkRoleHeadingConvention, ROLE_HEADING_PINS } from '../../scripts/lint-doc-drift.mjs';

const fx = (name) => path.join(import.meta.dirname, 'fixtures', 'lint', name, 'skills');
const ROLE_MAP = path.resolve(import.meta.dirname, '..', '..', 'hooks', 'lib', 'schema-role-map.sh');
const has = (r, re) => r.detail.some((l) => re.test(l));

// ── Check 7 — pi-kernel entries resolve ──────────────────────────────────────────────────────────

test('GREEN: an entry resolves as an exact heading, as a unique substring, and as "<parent> > <child>"', () => {
  const r = checkPiKernelEntries(fx('kernel-green'));
  assert.deepEqual(r.detail, []);
  assert.equal(r.ok, true);
  assert.match(r.label, /3 entries across 1 skills/);
});

test('RED: an entry that names no heading fails, naming the skill, the entry and the delimiter', () => {
  const r = checkPiKernelEntries(fx('kernel-red'));
  assert.equal(r.ok, false);
  assert.ok(has(r, /typo-skill\/SKILL\.md: pi-kernel entry "The sign-off gaet" names no heading of this skill/), r.detail.join('\n'));
  assert.ok(has(r, /stops travelling with the skill/));
  assert.ok(has(r, /separated by "\|"/));
});

test('RED: an entry that matches several headings fails, printing the candidates and the path form', () => {
  const r = checkPiKernelEntries(fx('kernel-red'));
  assert.ok(has(r, /ambiguous-skill\/SKILL\.md: pi-kernel entry "Hard rules" matches 2 headings/), r.detail.join('\n'));
  assert.ok(has(r, /"Hard rules — kernel-resident", "Hard rules — kernel-resident"/));
  assert.ok(has(r, /declares NEITHER; name one as "<parent> > <child>"/));
});

test('RED: two entries naming the same heading, and an empty declaration, each fail', () => {
  const r = checkPiKernelEntries(fx('kernel-red'));
  assert.ok(has(r, /duplicate-skill\/SKILL\.md: pi-kernel entries "Exit gate — compliance sweep" and "Exit gate" both name "Exit gate — compliance sweep"/), r.detail.join('\n'));
  assert.ok(has(r, /empty-skill\/SKILL\.md: pi-kernel: is present but names nothing/));
});

test('the real tree passes, and it is the 15 annotated skills that are being checked', () => {
  const r = checkPiKernelEntries();
  assert.deepEqual(r.detail, []);
  assert.match(r.label, /42 entries across 15 skills/);
});

// ── Check 8 — the role-derivation convention, both directions ────────────────────────────────────

test('GREEN: a heading that prints its pinned role token passes', () => {
  const r = checkRoleHeadingConvention(fx('roles-green'), ROLE_MAP, [['reviewer-skill', 'workflow-reviewer-phase5']]);
  assert.deepEqual(r.detail, []);
  assert.match(r.label, /1 pinned roles, 1 found, 17 role stems/);
});

test('RED direction 1: a heading renamed to drop its role token fails, naming the role and the skill', () => {
  const r = checkRoleHeadingConvention(fx('roles-red'), ROLE_MAP, [['renamed-skill', 'workflow-reviewer-phase5'], ['dup-skill', 'probe-twice']]);
  assert.equal(r.ok, false);
  assert.ok(has(r, /skills\/renamed-skill\/SKILL\.md: no heading prints the dispatch role token `workflow-reviewer-phase5` any more/), r.detail.join('\n'));
  assert.ok(has(r, /loses its start section/));
  assert.ok(has(r, /roleSection in pi\/extensions\/achilles\/agent-tool\.ts/));
});

test('RED direction 2: a heading printing an unpinned role token fails, and so does an ambiguous one', () => {
  const r = checkRoleHeadingConvention(fx('roles-red'), ROLE_MAP, [['renamed-skill', 'workflow-reviewer-phase5'], ['dup-skill', 'probe-twice']]);
  // The direction that earns its keep: a NEW role heading the adapter may not be able to parse.
  assert.ok(has(r, /skills\/extra-skill\/SKILL\.md: heading "Per pass \(`composer-brand-new`\)" prints the dispatch role token `composer-brand-new` but the pair is not pinned/), r.detail.join('\n'));
  assert.ok(has(r, /add \['extra-skill', 'composer-brand-new'\] to ROLE_HEADING_PINS/));
  assert.ok(has(r, /skills\/dup-skill\/SKILL\.md: 2 headings contain the role token `probe-twice`/));
});

test('the role stems come from schema-role-map.sh, not from the pin list', () => {
  // A token that no case glob in the role map covers is not a role, so it is not this check's
  // business: the fixture's `composer-brand-new` fails only because `composer-*` IS a case there.
  const r = checkRoleHeadingConvention(fx('roles-red'), ROLE_MAP, []);
  assert.ok(has(r, /`composer-brand-new`/));
  assert.ok(!has(r, /`workflow-reviewer-phase5`/), 'the renamed skill prints no token at all');
});

test('the real tree passes: every pinned role still resolves and nothing new is unpinned', () => {
  const r = checkRoleHeadingConvention();
  assert.deepEqual(r.detail, []);
  assert.equal(ROLE_HEADING_PINS.length, 21);
  assert.match(r.label, /21 pinned roles, 21 found, 17 role stems/);
});
