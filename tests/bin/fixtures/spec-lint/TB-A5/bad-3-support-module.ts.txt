// spec-lint fixture: inline selectors are banned in support modules too
// place: tests/e2e/flows/cart-flow.ts
// rules: TB-A5
import type { Page } from '@playwright/test';

export async function openCart(page: Page) {
  await page.locator('[data-test=cart]').click(); // EXPECT TB-A5
}
