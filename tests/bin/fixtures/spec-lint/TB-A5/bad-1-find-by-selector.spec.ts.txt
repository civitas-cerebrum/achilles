// spec-lint fixture: a selector literal handed to findBySelector
// rules: TB-A5
import { test, expect } from './fixtures/base';

test('TC-0050 · removes a row', async ({ steps }) => {
  await steps.on('row', 'CartPage').findBySelector('button.remove').click(); // EXPECT TB-A5
});
