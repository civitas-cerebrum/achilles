// spec-lint fixture: a well-formed waiver of a waivable rule
// rules: TB-G1 TB-A2
import { test, expect } from './fixtures/base';

test('TC-0415 · emulates dark mode', async ({ page, steps }) => {
  // achilles-allow TB-A2 -- emulateMedia has no Steps form and the dark theme needs it
  await page.emulateMedia({ colorScheme: 'dark' }); // EXPECT TB-A2/waived
  await steps.verifyPresence('darkBanner', 'HomePage');
});
