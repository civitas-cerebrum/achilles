// spec-lint fixture: a raw navigation that has a Steps equivalent
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0010 · opens the login page', async ({ page }) => {
  await page.goto('/login'); // EXPECT TB-A2
});
