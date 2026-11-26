// spec-lint fixture: repository elements passed to the framework itself
// rules: TB-A11
import { test, expect } from './fixtures/base';

test('TC-0114 · drags a card', async ({ steps, repo }) => {
  const zone = await repo.get('doneColumn', 'BoardPage');
  await steps.dragAndDrop('card', 'BoardPage', { target: zone });
  await Promise.all([steps.click('save', 'BoardPage'), steps.verifyPresence('toast', 'BoardPage')]);
});
