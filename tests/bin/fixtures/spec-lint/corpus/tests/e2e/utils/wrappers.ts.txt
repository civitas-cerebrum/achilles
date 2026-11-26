// Corpus support module: raw Playwright behind an imported wrapper.
import type { Page } from '@playwright/test';

export const clickCss = (page: Page, s: string) => page.locator(s).click(); // EXPECT TB-A12
export async function readTitle(page: Page) { return page.title(); } // EXPECT TB-A12
export async function seedOrder(page: Page) { return page.request.post('/api/orders', { data: {} }); } // CLEAN-BLOCKING TB-A12
