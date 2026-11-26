// spec-lint fixture: a web-first matcher on a locator
// rules: TB-A3
import { test, expect } from './fixtures/base';

test('TC-0030 · the alert shows', async ({ page }) => {
  await expect(page.getByRole('alert')).toBeVisible(); // EXPECT TB-A3
});
