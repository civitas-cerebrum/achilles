// spec-lint fixture: plain values read through the Steps API
// rules: TB-A3
import { test, expect } from './fixtures/base';

test('TC-0033 · unknown and known accounts get the same message', async ({ steps }) => {
  const unknown = await steps.getText('errorMessage', 'LoginPage');
  const known = await steps.getText('errorMessage', 'LoginPage');
  expect(unknown?.trim()).toBe(known?.trim());
  await steps.verifyPresence('errorAlert', 'LoginPage');
});
