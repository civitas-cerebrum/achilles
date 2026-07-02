#!/usr/bin/env node
// validate-schema-fixtures.mjs
// For each schemas/subagent-returns/<role>.schema.json, verifies that
// fixtures/<role>-valid.yaml passes and fixtures/<role>-invalid.yaml
// fails. Also validates the schemas/onboarding-status.schema.json fixtures
// under schemas/onboarding-status.fixtures/ (every valid-*.json must
// validate; every invalid-*.json must fail). Exits non-zero on any mismatch.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { parse } from 'yaml';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const dir = 'schemas/subagent-returns';
const fixturesDir = join(dir, 'fixtures');
// `allowUnionTypes` accommodates the handover envelope's `cycle` union
// (integer | string), which the spec deliberately permits. `strictSchema:
// false` keeps Ajv tolerant of vendor keywords.
const ajv = new Ajv({
  strict: true,
  allErrors: true,
  loadSchema: false,
  allowUnionTypes: true,
  strictSchema: false,
});
addFormats(ajv);

const handover = JSON.parse(readFileSync(join(dir, 'handover.schema.json'), 'utf8'));
ajv.addSchema(handover);

const schemaFiles = readdirSync(dir).filter(f => f.endsWith('.schema.json') && f !== 'handover.schema.json');

let failures = 0;
for (const file of schemaFiles) {
  const role = basename(file, '.schema.json');
  const schema = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  const validate = ajv.compile(schema);

  const validPath = join(fixturesDir, `${role}-valid.yaml`);

  const validData = parse(readFileSync(validPath, 'utf8'));
  if (!validate(validData)) {
    console.error(`FAIL: ${validPath} did not validate against ${file}`);
    console.error(validate.errors);
    failures++;
  } else {
    console.log(`OK:   ${validPath} validates against ${file}`);
  }

  // Every invalid fixture for the role must fail: the canonical
  // `<role>-invalid.yaml` plus any focused `<role>-invalid-<case>.yaml`
  // variants (e.g. -invalid-bad-status). One-violation-per-file keeps each
  // negative fixture honest — a bundled multi-violation fixture can hide a
  // schema gap by failing for the wrong reason.
  const invalidFixtures = readdirSync(fixturesDir).filter(
    n => (n === `${role}-invalid.yaml` || n.startsWith(`${role}-invalid-`)) && n.endsWith('.yaml'),
  );
  if (invalidFixtures.length === 0) {
    console.error(`FAIL: no invalid fixture found for role ${role} (expected ${role}-invalid.yaml)`);
    failures++;
  }
  for (const inv of invalidFixtures) {
    const invalidPath = join(fixturesDir, inv);
    const invalidData = parse(readFileSync(invalidPath, 'utf8'));
    if (validate(invalidData)) {
      console.error(`FAIL: ${invalidPath} unexpectedly validated against ${file}`);
      failures++;
    } else {
      console.log(`OK:   ${invalidPath} correctly fails ${file}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Handover envelope fixtures
// ---------------------------------------------------------------------------
// The handover envelope is excluded from the role loop above (it is the
// shared $ref target, not a role return), so its fixtures would otherwise
// go unexercised. Compile it directly and assert handover-valid.yaml passes
// while handover-invalid.yaml genuinely fails — the latter is only a real
// negative now that the envelope carries required/minLength/minimum
// constraints (cross-cutting §14).
{
  const validateHandover = ajv.compile(handover);
  const handoverValidPath = join(fixturesDir, 'handover-valid.yaml');
  const handoverInvalidPath = join(fixturesDir, 'handover-invalid.yaml');

  const handoverValid = parse(readFileSync(handoverValidPath, 'utf8'));
  if (!validateHandover(handoverValid)) {
    console.error(`FAIL: ${handoverValidPath} did not validate against handover.schema.json`);
    console.error(validateHandover.errors);
    failures++;
  } else {
    console.log(`OK:   ${handoverValidPath} validates against handover.schema.json`);
  }

  const handoverInvalid = parse(readFileSync(handoverInvalidPath, 'utf8'));
  if (validateHandover(handoverInvalid)) {
    console.error(`FAIL: ${handoverInvalidPath} unexpectedly validated against handover.schema.json`);
    failures++;
  } else {
    console.log(`OK:   ${handoverInvalidPath} correctly fails handover.schema.json`);
  }
}

// ---------------------------------------------------------------------------
// Standalone-schema fixtures (valid-*/invalid-* convention)
// ---------------------------------------------------------------------------
// Each standalone schema lives one directory up and owns a sibling
// <name>.fixtures/ dir. Convention mirrors onboarding-status:
//   valid-*.json   must validate; invalid-*.json must fail.
function validateStandaloneFixtures(schemaPath, fixturesDirPath) {
  if (!existsSync(schemaPath) || !existsSync(fixturesDirPath)) return;
  const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
  const standaloneAjv = new Ajv({
    strict: true,
    allErrors: true,
    loadSchema: false,
    allowUnionTypes: true,
    strictSchema: false,
  });
  addFormats(standaloneAjv);
  const validateFn = standaloneAjv.compile(schema);

  for (const f of readdirSync(fixturesDirPath).filter(n => n.endsWith('.json'))) {
    const full = join(fixturesDirPath, f);
    const data = JSON.parse(readFileSync(full, 'utf8'));
    const expectValid = f.startsWith('valid-');
    const ok = validateFn(data);
    if (expectValid && !ok) {
      console.error(`FAIL: ${full} did not validate against ${schemaPath}`);
      console.error(validateFn.errors);
      failures++;
    } else if (!expectValid && ok) {
      console.error(`FAIL: ${full} unexpectedly validated against ${schemaPath}`);
      failures++;
    } else {
      console.log(`OK:   ${full} ${expectValid ? 'validates' : 'correctly fails'} against ${schemaPath}`);
    }
  }
}

validateStandaloneFixtures('schemas/contribution-handover.schema.json', 'schemas/contribution-handover.fixtures');
validateStandaloneFixtures('schemas/run-summary.schema.json', 'schemas/run-summary.fixtures');
validateStandaloneFixtures('schemas/perf-onboarding-status.schema.json', 'schemas/perf-onboarding-status.fixtures');
validateStandaloneFixtures('schemas/perf-summary.schema.json', 'schemas/perf-summary.fixtures');

// ---------------------------------------------------------------------------
// Onboarding-status ledger fixtures
// ---------------------------------------------------------------------------
// Validates the onboarding-status.schema.json fixtures. Convention:
//   schemas/onboarding-status.fixtures/valid-*.json   must validate
//   schemas/onboarding-status.fixtures/invalid-*.json must fail
const onboardingSchemaPath = 'schemas/onboarding-status.schema.json';
const onboardingFixturesDir = 'schemas/onboarding-status.fixtures';
if (existsSync(onboardingSchemaPath) && existsSync(onboardingFixturesDir)) {
  const onboardingSchema = JSON.parse(readFileSync(onboardingSchemaPath, 'utf8'));
  // Use a fresh Ajv instance — the onboarding-status schema is a
  // standalone document, not a member of the subagent-return collection.
  const ajvOnboarding = new Ajv({
    strict: true,
    allErrors: true,
    loadSchema: false,
    allowUnionTypes: true,
    strictSchema: false,
  });
  addFormats(ajvOnboarding);
  const validateOnboarding = ajvOnboarding.compile(onboardingSchema);

  for (const f of readdirSync(onboardingFixturesDir).filter(n => n.endsWith('.json'))) {
    const full = join(onboardingFixturesDir, f);
    const data = JSON.parse(readFileSync(full, 'utf8'));
    const expectValid = f.startsWith('valid-');
    const ok = validateOnboarding(data);
    if (expectValid && !ok) {
      console.error(`FAIL: ${full} did not validate against ${onboardingSchemaPath}`);
      console.error(validateOnboarding.errors);
      failures++;
    } else if (!expectValid && ok) {
      console.error(`FAIL: ${full} unexpectedly validated against ${onboardingSchemaPath}`);
      failures++;
    } else {
      console.log(`OK:   ${full} ${expectValid ? 'validates' : 'correctly fails'} against ${onboardingSchemaPath}`);
    }
  }
}

process.exit(failures === 0 ? 0 : 1);
