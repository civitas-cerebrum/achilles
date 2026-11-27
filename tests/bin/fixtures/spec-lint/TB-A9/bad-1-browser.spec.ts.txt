// spec-lint fixture: a raw browser fixture in a test (advisory); option fixtures are fine
// rules: TB-A9
import { test, expect } from './fixtures/base';

test('TC-0090 · a second session sees the change', async ({ browser, baseURL, steps }) => { // EXPECT TB-A9/advisory
  await steps.navigateTo(baseURL ?? '/');
  expect(browser).toBeTruthy();
});
