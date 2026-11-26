// spec-lint fixture: a context and a locator handed to helpers (direct form)
// rules: TB-A11
import { setAuthCookie, expectHidden } from './utils/session';
import { test, expect } from './fixtures/base';

test('TC-0111 · the session cookie is set', async ({ page }) => {
  await setAuthCookie(page.context(), 'user-1'); // EXPECT TB-A11
  const row = page.locator('#row');
  await expectHidden(row); // EXPECT TB-A11
});
