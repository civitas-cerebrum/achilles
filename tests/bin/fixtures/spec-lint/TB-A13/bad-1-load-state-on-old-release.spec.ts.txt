// spec-lint fixture: waitForLoadState has a Steps equivalent only from a newer release
// pin: 0.3.6
// rules: TB-A13 TB-A2
// expect-project: TB-A13
import { test, expect } from './fixtures/base';

test('TC-0130 · waits for the page', async ({ page }) => {
  await page.waitForLoadState('networkidle'); // EXPECT TB-A13/advisory
});
