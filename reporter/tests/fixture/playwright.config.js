// Fixture project for the reporter's integration tests. Deliberately
// browser-free: the reporter's inputs are attachments, attempts and statuses,
// all of which a plain Node test produces, so the suite runs anywhere without
// a browser download. The integration test copies this tree into a scratch
// directory and points ACHILLES_REPORTER_ENTRY at the reporter under test.
const path = require('node:path');

module.exports = {
  testDir: './tests',
  retries: Number(process.env.FIXTURE_RETRIES || 1),
  workers: 1,
  reporter: [
    ['json', { outputFile: 'reports/results.json' }],
    [process.env.ACHILLES_REPORTER_ENTRY || path.resolve(__dirname, '../../index.js')],
  ],
};
