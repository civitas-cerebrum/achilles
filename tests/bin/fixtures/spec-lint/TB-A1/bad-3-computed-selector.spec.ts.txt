// spec-lint fixture: a raw locator built from a variable is A1 without A5
// rules: TB-A1 TB-A5
import { test, expect } from './fixtures/base';

test('TC-0002 · uses a computed selector', async ({ page }) => {
  const sel = process.env.SEL || '';
  await page.locator(sel).hover(); // EXPECT TB-A1
});
