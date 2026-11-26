// spec-lint fixture: TypeScript generics, satisfies and decorators parse
// rules: TB-G0
import { test, expect } from './fixtures/base';

type Row = { name: string };
const rows = [{ name: 'a' }] satisfies Row[];

test('TC-0401 · parses', async ({ steps }) => {
  const first = rows.at(0)!;
  await steps.verifyText<string>('nameCell', 'TablePage', first.name);
});
