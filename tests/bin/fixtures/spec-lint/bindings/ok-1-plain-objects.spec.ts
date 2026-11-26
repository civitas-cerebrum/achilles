// spec-lint fixture: plain data named like driver members is not a binding
// rules: TB-A1 TB-A2 TB-A11
import { test, expect } from './fixtures/base';

test('TC-0508 · reads data', async ({ steps }) => {
  const book = { title: 'x', locator: () => 'y', goto: () => 'z' };
  const { title } = book;
  book.locator();
  book.goto();
  await steps.verifyText('heading', 'BookPage', title);
});
