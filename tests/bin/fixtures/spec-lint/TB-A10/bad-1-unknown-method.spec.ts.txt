// spec-lint fixture: a Steps method the installed release does not have
// rules: TB-A10
import { test, expect } from './fixtures/base';

test('TC-0100 · checks the button', async ({ steps }) => {
  await steps.getLocator('submitButton', 'LoginPage'); // EXPECT TB-A10
});
