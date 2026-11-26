// spec-lint fixture: a framework-gap citation naming a row that does not cover the call
// rules: TB-G1
import { test, expect } from './fixtures/base';

test('TC-0413 · mocks the catalogue', async ({ page }) => {
  // EXPECT-NEXT TB-G1
  // framework-gap: FG-1
  await page.route('**/api/catalogue', (route) => route.fulfill({ json: [] }));
});
