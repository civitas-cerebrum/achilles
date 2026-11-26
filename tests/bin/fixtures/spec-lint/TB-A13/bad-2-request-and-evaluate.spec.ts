// spec-lint fixture: below the release with requestGet the strict reading has no equivalent; evaluate below getLocalStorage
// pin: 0.3.3
// rules: TB-A13 TB-A2 TB-A4
// expect-project: TB-A13
import { test, expect } from './fixtures/base';

test('TC-0131 · reads the cart', async ({ page, request }) => {
  await request.get('/api/cart'); // EXPECT TB-A13/advisory
  const theme = await page.evaluate(() => localStorage.getItem('theme')); // EXPECT TB-A13/advisory
  expect(theme).toBe('dark');
});
