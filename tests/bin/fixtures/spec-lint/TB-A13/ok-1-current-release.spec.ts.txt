// spec-lint fixture: on a current release the same call is A2, not A13
// rules: TB-A13
import { test, expect } from './fixtures/base';

test('TC-0132 · waits for the page', async ({ page }) => {
  await page.waitForLoadState('networkidle');
});
