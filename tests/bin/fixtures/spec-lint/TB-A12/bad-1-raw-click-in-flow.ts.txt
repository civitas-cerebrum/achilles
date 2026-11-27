// spec-lint fixture: a raw UI call inside a flow
// place: tests/e2e/flows/checkout-flow.ts
// rules: TB-A12
import type { Page } from '@playwright/test';
import type { Steps } from '@civitas-cerebrum/element-interactions';

export async function openCart(steps: Steps, page: Page) {
  await page.click('#cart'); // EXPECT TB-A12
  await steps.verifyPresence('cartPanel', 'HeaderPage');
}
