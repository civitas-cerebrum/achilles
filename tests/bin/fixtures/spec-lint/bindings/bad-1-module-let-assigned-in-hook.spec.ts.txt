// spec-lint fixture: a module-level page declared by type and assigned in beforeAll
// rules: TB-A1 TB-A2
import type { Page } from '@playwright/test';
import { test, expect } from './fixtures/base';

let shared: Page;
test.beforeAll(async ({ browser }) => { shared = await browser.newPage(); });

test('TC-0500 · uses the shared page', async () => {
  await shared.goto('/x'); // EXPECT TB-A2
});
