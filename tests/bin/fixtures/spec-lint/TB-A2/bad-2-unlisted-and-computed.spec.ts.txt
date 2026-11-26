// spec-lint fixture: methods in neither table and a computed member are A2 too
// rules: TB-A2
import { test, expect } from './fixtures/base';

test('TC-0011 · emulates and pokes', async ({ page, context }) => {
  const m = 'reload';
  await page.emulateMedia({ colorScheme: 'dark' }); // EXPECT TB-A2
  await context.grantPermissions(['clipboard-read']); // EXPECT TB-A2
  await page[m](); // EXPECT TB-A2
});
