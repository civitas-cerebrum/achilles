const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');

// Evidence stands in for a trace/video/screenshot: a real attachment with a
// real path, which is all the reporter consumes.
async function attach(testInfo, body) {
  const file = testInfo.outputPath('evidence.txt');
  fs.writeFileSync(file, body);
  await testInfo.attach('evidence', { path: file, contentType: 'text/plain' });
}

test('steady', async ({}, testInfo) => {
  await attach(testInfo, `attempt ${testInfo.retry}`);
  expect(1).toBe(1);
});

test('always red', async ({}, testInfo) => {
  await attach(testInfo, `attempt ${testInfo.retry}`);
  expect(testInfo.retry).toBe(-1);
});

test('red then green', async ({}, testInfo) => {
  await attach(testInfo, `attempt ${testInfo.retry}`);
  // Passes only on the first retry, producing a genuine flaky outcome.
  expect(testInfo.retry).toBeGreaterThan(0);
});

test('skipped one', async ({}) => {
  test.skip(true, 'fixture');
});
