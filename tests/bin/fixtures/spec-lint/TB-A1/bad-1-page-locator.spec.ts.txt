// spec-lint fixture: a raw locator read in a test (the chain reports once)
// rules: TB-A1 TB-A5
import { test, expect } from './fixtures/base';

test('TC-0001 · reads the summary', async ({ page }) => {
  const text = await page.locator('main').innerText(); // EXPECT TB-A1 TB-A5
});
