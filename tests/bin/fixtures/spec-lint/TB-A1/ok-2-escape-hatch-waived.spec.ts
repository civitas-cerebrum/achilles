// spec-lint fixture: the framework-gap escape hatch, one raw call, with a waiver
// rules: TB-A1 TB-A11 TB-G1
import { WebElement } from '@civitas-cerebrum/element-interactions';
import { test, expect } from './fixtures/base';

test('TC-0004 · opens the hover menu', async ({ page, repo, interactions }) => {
  // achilles-allow TB-A1 -- the hover-intent submenu needs a raw locator chain
  await interactions.interact.hover(new WebElement(page.locator(repo.getSelector('submenu', 'NavPage')))); // EXPECT TB-A1/waived
});
