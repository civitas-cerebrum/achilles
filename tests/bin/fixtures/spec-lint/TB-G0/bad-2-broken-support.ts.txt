// spec-lint fixture: a support module that does not parse
// place: tests/e2e/flows/broken-flow.ts
// rules: TB-G0
// expect-file: TB-G0
export async function open(steps) {
  await steps.click('a', 'B'
}
