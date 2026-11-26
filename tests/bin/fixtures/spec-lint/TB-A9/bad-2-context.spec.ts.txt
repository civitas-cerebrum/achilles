// spec-lint fixture: a raw context fixture in a test (advisory)
// rules: TB-A9
import { test, expect } from './fixtures/base';

test('TC-0091 · signs out', async ({ context, steps }) => { // EXPECT TB-A9/advisory
  await steps.navigateTo('/logout');
  expect(context).toBeTruthy();
});
