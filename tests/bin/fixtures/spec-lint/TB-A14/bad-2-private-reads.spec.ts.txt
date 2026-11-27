// spec-lint fixture: private and underscore members, a literal computed key, interactions parts
// rules: TB-A14
import { test, expect } from './fixtures/base';

test('TC-0141 · reads private fields', async ({ steps, repo, interactions }) => {
  const p = steps.page; // EXPECT TB-A14
  const t = steps._timeout; // EXPECT TB-A14
  const d = repo['driver']; // EXPECT TB-A14
  const ip = interactions.interact.page; // EXPECT TB-A14
  expect([p, t, d, ip].length).toBe(4);
});
