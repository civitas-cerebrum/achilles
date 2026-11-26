// spec-lint fixture: a spec-local extend body is checked like a test
// rules: TB-A1 TB-A2
import type { BrowserContext } from '@playwright/test';
import { test, expect } from './fixtures/base';

const it = test.extend<{ ctx2: BrowserContext }>({
  ctx2: async ({ browser }, use) => {
    const c = await browser.newContext();
    const p = await c.newPage();
    await p.goto('/warm'); // EXPECT TB-A2
    await use(c);
  },
});
it('TC-0504 · uses the second context', async ({ ctx2 }) => {
  const p = await ctx2.newPage();
  await p.getByRole('heading').isVisible(); // EXPECT TB-A1
});
