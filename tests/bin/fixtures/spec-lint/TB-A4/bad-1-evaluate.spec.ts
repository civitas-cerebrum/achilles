// spec-lint fixture: page scripting when steps.getLocalStorage exists
// rules: TB-A4 TB-A13
import { test, expect } from './fixtures/base';

test('TC-0040 · keeps the theme', async ({ page }) => {
  const theme = await page.evaluate(() => localStorage.getItem('theme')); // EXPECT TB-A4
  expect(theme).toBe('dark');
});
