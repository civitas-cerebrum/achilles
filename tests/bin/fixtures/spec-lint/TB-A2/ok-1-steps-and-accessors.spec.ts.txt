// spec-lint fixture: Steps navigation and the plain accessors
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0013 · opens the login page', async ({ steps, page }) => {
  await steps.navigateTo('/login');
  const ctx = page.context();
  const main = page.mainFrame();
  expect([ctx, main].length).toBe(2);
});
