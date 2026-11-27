// spec-lint fixture: the page handed to a helper (direct form)
// rules: TB-A11
import { clickCss } from './utils/wrappers';
import { test, expect } from './fixtures/base';

test('TC-0110 · pays', async ({ page }) => {
  await clickCss(page, '#pay'); // EXPECT TB-A11
});
