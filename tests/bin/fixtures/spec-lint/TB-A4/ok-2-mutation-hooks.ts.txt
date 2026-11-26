// spec-lint fixture: the verify-change mutation hooks in the fixtures module, gated on their variables
// place: tests/e2e/fixtures/base.ts
// rules: TB-A4 TB-A12
import { test as base } from '@playwright/test';
import { baseFixture } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/e2e/page-repository.json').extend({
  page: async ({ page }, use) => {
    if (process.env.E2E_MUTATION_CSS) await page.addStyleTag({ content: process.env.E2E_MUTATION_CSS });
    if (process.env.E2E_MUTATION_INIT) await page.addInitScript(process.env.E2E_MUTATION_INIT);
    await use(page);
  },
});
