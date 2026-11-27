// spec-lint fixture: the Steps method itself
// pin: 0.3.8
// rules: TB-A13
import { test, expect } from './fixtures/base';

test('TC-0133 · waits for the page', async ({ steps }) => {
  await steps.waitForLoadState('networkidle');
});
