// spec-lint fixture: an unknown rule id, a missing separator, and a waiver on a code line
// rules: TB-G1
import { test, expect } from './fixtures/base';

test('TC-0414 · waives oddly', async ({ page }) => {
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-Z9 -- the rule id does not exist in the rulebook
  await page.goto('/a');
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A2 the separator before the reason is missing here
  await page.goto('/b');
  await page.goto('/c'); // achilles-allow TB-A2 -- trailing waivers are not the grammar EXPECT TB-G1
});
