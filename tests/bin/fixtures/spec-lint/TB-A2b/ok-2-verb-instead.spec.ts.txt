// spec-lint fixture: the spec calls a verb instead of the raw call
// rules: TB-A2b TB-A2
import { expireSession } from './flows/session';
import { test, expect } from './fixtures/base';

test('TC-0022 · an expired session returns to the login form', async ({ steps }) => {
  await expireSession(steps);
  await steps.verifyPresence('loginForm', 'LoginPage');
});
