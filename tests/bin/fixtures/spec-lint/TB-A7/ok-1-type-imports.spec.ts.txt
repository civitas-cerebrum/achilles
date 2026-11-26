// spec-lint fixture: type-only imports from Playwright are allowed
// rules: TB-A7
import type { Page } from '@playwright/test';
import { type Locator } from '@playwright/test';
import { test, expect } from './fixtures/base';

test('TC-0072 · runs', async ({ steps }) => {
  const p: Page | Locator | null = null;
  await steps.navigateTo(p ? '/a' : '/b');
});
