// spec-lint fixture: unlisted members are A2 with the no-known-equivalent message
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0507 · uses unlisted members', async ({ page }) => {
  const box = page.getByTestId('agree');
  expect(await box.isHidden()).toBe(false); // EXPECT TB-A2
  await box.setChecked(true); // EXPECT TB-A2
  await page.waitForRequest('**/api'); // EXPECT TB-A2
});
