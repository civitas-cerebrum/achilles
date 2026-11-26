// spec-lint fixture: public members of the framework objects
// rules: TB-A14
import { test, expect } from './fixtures/base';

test('TC-0144 · pays', async ({ steps, repo, interactions }) => {
  await steps.click('payButton', 'PayPage');
  const el = await repo.get('payButton', 'PayPage');
  await interactions.interact.clickWithoutScrolling(el);
  await interactions.verify.presence(el);
});
