// spec-lint fixture: a waiver of an unwaivable rule does not waive it
// rules: TB-G1 TB-A5
import { test, expect } from './fixtures/base';

test('TC-0411 · waives an inline selector', async ({ steps }) => {
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A5 -- the shadow root has no repository entry yet
  await steps.on('host', 'ShadowPage').findBySelector('.inner').click(); // EXPECT TB-A5
});
