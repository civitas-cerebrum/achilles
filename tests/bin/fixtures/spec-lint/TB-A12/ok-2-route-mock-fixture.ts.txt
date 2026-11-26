// spec-lint fixture: a cited route mock and a lifecycle-owning fixture in the fixtures module
// place: tests/e2e/fixtures/base.ts
// rules: TB-A12 TB-G1
import { test as base } from '@playwright/test';
import { baseFixture } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/e2e/page-repository.json').extend({
  emptyCatalogue: async ({ page }, use) => {
    // framework-gap: FG-2
    await page.route('**/api/catalogue', async (route) => { await route.fulfill({ json: [] }); });
    await use(page);
  },
  secondContext: async ({ browser }, use) => {
    const ctx = await browser.newContext();
    await use(ctx);
    await ctx.close();
  },
});
