// spec-lint fixture: a computed member with a non-literal key on the page
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0506 · calls a computed method', async ({ page }) => {
  const m = ['click', 'tap'][0];
  await page[m]('#x'); // EXPECT TB-A2
});
