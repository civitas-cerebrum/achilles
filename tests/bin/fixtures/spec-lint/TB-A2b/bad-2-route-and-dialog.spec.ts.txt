// spec-lint fixture: network mocking and dialog capture in a spec (advisory)
// rules: TB-A2b TB-A2
import { test, expect } from './fixtures/base';

test('TC-0021 · mocks the catalogue', async ({ page }) => {
  await page.route('**/api/catalogue', (route) => route.fulfill({ json: [] })); // EXPECT TB-A2b/advisory
  page.on('dialog', (d) => d.accept()); // EXPECT TB-A2b/advisory
});
