// spec-lint fixture: a waiver with a stock reason
// rules: TB-G1 TB-A1
import { test, expect } from './fixtures/base';

test('TC-0410 · waives badly', async ({ page }) => {
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A1 -- needed
  await page.locator(process.env.SEL || '').click(); // EXPECT TB-A1
});
