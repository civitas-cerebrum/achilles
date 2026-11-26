// spec-lint fixture: an untyped extend whose kind comes from what use(...) receives
// rules: TB-A2
import { test, expect } from './fixtures/base';

const it = test.extend({ authed: async ({ page }, use) => use(page) });

it('TC-0503 · uses the authed page', async ({ authed }) => {
  await authed.reload(); // EXPECT TB-A2
});
