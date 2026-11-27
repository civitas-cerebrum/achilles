// spec-lint fixture: type escapes applied to framework objects
// rules: TB-A14
import { test, expect } from './fixtures/base';

test('TC-0143 · escapes the types', async ({ steps, repo }) => {
  const s = steps as unknown as { shown: boolean }; // EXPECT TB-A14
  const alias: any = repo; // EXPECT TB-A14
  // @ts-ignore
  const hidden = steps.click; // EXPECT TB-A14
  expect([s, alias, hidden].length).toBe(3);
});
