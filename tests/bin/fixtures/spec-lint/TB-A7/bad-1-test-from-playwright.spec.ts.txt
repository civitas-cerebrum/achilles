// spec-lint fixture: test and expect imported from Playwright
// rules: TB-A7
import { test, expect } from '@playwright/test'; // EXPECT TB-A7

test('TC-0070 · runs', async ({ page }) => {
  expect(page).toBeTruthy();
});
