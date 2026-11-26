// spec-lint fixture: URL-taking steps never carry selectors, whatever their strings look like
// rules: TB-A5
import { test, expect } from './fixtures/base';

test('TC-0052 · opens the anchored section', async ({ steps }) => {
  await steps.navigateTo('/orders#latest');
  await steps.verifyUrlContains('#latest');
  await steps.apiGet('/api/items?sort=.name');
  await steps.click('submitButton', 'LoginPage');
});
