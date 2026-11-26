// spec-lint fixture: more than two waivers in one test
// rules: TB-G1
import { test, expect } from './fixtures/base';

test('TC-0412 · waives three times', async ({ page }) => {
  // achilles-allow TB-A2 -- the media emulation has no Steps form at all
  await page.emulateMedia({ colorScheme: 'dark' });
  // achilles-allow TB-A2 -- the permission grant has no Steps form either
  await page.context().grantPermissions(['geolocation']);
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A2 -- the bring-to-front call has no Steps form
  await page.bringToFront();
});
