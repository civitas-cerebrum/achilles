// spec-lint fixture: a framework-gap citation naming the row that covers the call
// rules: TB-G1
import { test, expect } from './fixtures/base';

test('TC-0416 · listens to the console', async ({ page, steps }) => {
  const seen: string[] = [];
  // framework-gap: FG-3
  page.on('console', (m) => seen.push(m.text()));
  await steps.navigateTo('/');
  expect(seen).toEqual([]);
});
