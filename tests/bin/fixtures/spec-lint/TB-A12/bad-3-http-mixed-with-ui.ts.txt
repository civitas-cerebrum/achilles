// spec-lint fixture: an HTTP call in a function that also drives the UI (HTTP part advisory)
// place: tests/e2e/utils/orders.ts
// rules: TB-A12
import type { Page } from '@playwright/test';

export async function createAndOpen(page: Page) {
  const res = await page.request.post('/api/orders', { data: {} }); // EXPECT TB-A12/advisory
  await page.goto('/orders/latest'); // EXPECT TB-A12
  return res;
}
