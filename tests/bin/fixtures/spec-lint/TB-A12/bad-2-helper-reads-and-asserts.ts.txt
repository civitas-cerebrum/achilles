// spec-lint fixture: raw reads and web-first assertions in a helper module
// place: tests/e2e/helpers/page-checks.ts
// rules: TB-A12
import { expect, type Page } from '@playwright/test';

export const readHeading = (page: Page) => page.locator('h1').textContent(); // EXPECT TB-A12
export async function onOrders(page: Page) {
  await expect(page).toHaveURL(/orders/); // EXPECT TB-A12
}
