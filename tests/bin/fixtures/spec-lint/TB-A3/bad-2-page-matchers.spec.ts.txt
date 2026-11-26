// spec-lint fixture: page matchers, negated and soft forms
// rules: TB-A3
import { test, expect } from './fixtures/base';

test('TC-0031 · lands on the orders page', async ({ page }) => {
  await expect(page).toHaveURL(/orders/); // EXPECT TB-A3
  await expect(page).not.toHaveTitle('Error'); // EXPECT TB-A3
  await expect.soft(page.locator('h1')).toContainText('Orders'); // EXPECT TB-A3
});
