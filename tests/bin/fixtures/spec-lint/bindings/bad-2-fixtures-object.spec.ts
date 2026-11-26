// spec-lint fixture: member reads on an undestructured fixtures object
// rules: TB-A1
import { test, expect } from './fixtures/base';

test('TC-0501 · reads through the fixtures object', async (fx) => {
  await fx.page.getByText('Save').click(); // EXPECT TB-A1
});
