// This build ships without the role kernel, so postinstall stages no mandate.
// An earlier install staged hooks/data/achilles-qa.kernel-mandate.json (and its
// human-readable ledger) under these names with a sidecar stamp; achilles-uninstall
// still removes those copies while they are unedited.
const STAMP_FILE = 'kernel-mandate.achilles.json';

const MANDATE_FILES = {
  project: { manifest: 'kernel-mandate.json', ledger: 'kernel-mandate.md' },
  global: { manifest: 'achilles-qa.kernel-mandate.json', ledger: 'achilles-qa.kernel-mandate.md' },
};

module.exports = { MANDATE_FILES, STAMP_FILE };
