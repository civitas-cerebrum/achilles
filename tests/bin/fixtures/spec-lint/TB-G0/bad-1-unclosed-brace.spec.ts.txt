// spec-lint fixture: a spec that does not parse
// rules: TB-G0
// expect-file: TB-G0
import { test, expect } from './fixtures/base';

test('TC-0400 · broken', async ({ steps }) => {
  await steps.click('submitButton', 'LoginPage') ;;
