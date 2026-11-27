// spec-lint fixture: init scripts and $eval on the page
// rules: TB-A4
import { test, expect } from './fixtures/base';

test('TC-0041 · reads the heading through the page', async ({ page }) => {
  await page.addInitScript(() => { (window as any).flag = true; }); // EXPECT TB-A4
  const h = await page.$eval('h1', (e) => e.textContent); // EXPECT TB-A4
  expect(h).toBe('Home');
});
