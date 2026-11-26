// spec-lint fixture: a selector-shaped element name, and waitForSelector with a literal
// rules: TB-A5
import { test, expect } from './fixtures/base';

test('TC-0051 · submits', async ({ steps, page }) => {
  await steps.click('#submit', 'LoginPage'); // EXPECT TB-A5
  await page.waitForSelector('.toast'); // EXPECT TB-A5
  await page.getByText(/Saved/).isVisible(); // EXPECT TB-A5
});
