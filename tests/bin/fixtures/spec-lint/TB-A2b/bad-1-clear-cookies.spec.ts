// spec-lint fixture: a no-equivalent raw call in a spec (advisory)
// rules: TB-A2b TB-A2
import { test, expect } from './fixtures/base';

test('TC-0020 · signs out by clearing cookies', async ({ context }) => {
  await context.clearCookies(); // EXPECT TB-A2b/advisory
});
