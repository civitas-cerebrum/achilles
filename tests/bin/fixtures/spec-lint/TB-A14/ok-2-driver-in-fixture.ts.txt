// spec-lint fixture: repo.driver inside the fixtures module body that builds the framework objects
// place: tests/e2e/fixtures/base.ts
// rules: TB-A14
import { test as base } from '@playwright/test';
import { baseFixture, Steps } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/e2e/page-repository.json').extend<{ adminSteps: Steps }>({
  adminSteps: async ({ repo }, use) => {
    await use(new Steps(repo, { timeout: 5_000 }).forPage(repo.driver));
  },
});
