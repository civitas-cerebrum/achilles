// spec-lint fixture: a member destructured from the page
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0502 · presses a key', async ({ page }) => {
  const { keyboard } = page;
  await keyboard.press('Escape'); // EXPECT TB-A2
});
