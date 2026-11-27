// spec-lint fixture: public methods of the installed surface, and chains on their results
// rules: TB-A10
import { test, expect } from './fixtures/base';

test('TC-0103 · the button is enabled', async ({ steps }) => {
  await steps.verifyState('submitButton', 'LoginPage', 'enabled');
  await steps.on('row', 'CartPage').ifVisible().click();
});
