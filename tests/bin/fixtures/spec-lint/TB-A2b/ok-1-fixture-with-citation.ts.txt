// spec-lint fixture: the no-equivalent call lives in a fixture and cites its register row
// place: tests/e2e/fixtures/base.ts
// rules: TB-A2b TB-A12 TB-G1
import { test as base } from '@playwright/test';
import { baseFixture } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/e2e/page-repository.json').extend<{ clearSessionCookies: () => Promise<void> }>({
  clearSessionCookies: async ({ context }, use) => {
    // framework-gap: FG-1
    await use(() => context.clearCookies());
  },
});
