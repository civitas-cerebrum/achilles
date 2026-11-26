// spec-lint fixture: framework fixtures and Playwright option fixtures
// rules: TB-A9
import { test, expect } from './fixtures/base';

test('TC-0092 · reads the locale', async ({ steps, repo, interactions, contextStore, page, locale }) => {
  await steps.navigateTo(locale ?? '/');
  expect([repo, interactions, contextStore, page].length).toBe(4);
});
