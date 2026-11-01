import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { derivedSlug } from '../hooks/bash-judge'
import { ROOT, START, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 02 (playwright-cli isolation), 42 (commit message), 79 (PR
// attribution), 64 (k6 load safety), 57/92 (protected state via the shell) and the adapter's
// force-push / rm -rf guard. Every pattern deny carries at least two adjacent-traffic allows.

async function setup($: EngineInterface, h: Harness, role = 'author') {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const agentId = await spawnExpert($, h, role, orchestrator)
  const bash = async (command: string, as = agentId) => $.tool.call({ tool: 'Bash', command, agentId: as })
  return { orchestrator, agentId, bash }
}

const ran = (h: Harness) => h.ran

test('force-push and rm -rf outside the project are denied for achilles loops; --force-with-lease, rm inside the project and the main loop pass', async ($, on) => {
  const h = engine(on)
  const { orchestrator, bash } = await setup($, h)
  expect((await bash('git push --force origin main')).deny).toMatch(/does not force-push/)
  expect((await bash('git push -f origin main', orchestrator)).deny).toMatch(/does not force-push/)
  expect((await bash('cd app && git -C . push origin +main --force')).deny).toMatch(/does not force-push/)
  expect((await bash('git push --force-with-lease origin main')).deny).toBeUndefined()
  expect((await bash('git push origin main')).deny).toBeUndefined()
  expect((await bash('rm -rf /tmp/other')).deny).toMatch(/outside the project/)
  expect((await bash('rm -r -f ~/old')).deny).toMatch(/outside the project/)
  expect((await bash('rm --recursive --force ../sibling')).deny).toMatch(/outside the project/)
  expect((await bash('cd /tmp && rm -fr build')).deny).toMatch(/outside the project/)
  expect((await bash(`rm -rf ${ROOT}/.achilles/reports`)).deny).toBeUndefined()
  expect((await bash('rm -rf test-results playwright-report')).deny).toBeUndefined()
  expect((await bash('rm -f /tmp/one-file')).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Bash', command: 'git push --force origin main' })).deny).toBeUndefined()
  expect((await bash('npx playwright test tests/e2e/login.spec.ts')).deny).toBeUndefined()
})

test('git commit: hook and signing bypasses are denied as git arguments, not as message text', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  for (const c of [
    "git commit --no-verify -m 'test(j-x): fix'",
    "git commit -n -m 'test(j-x): fix'",
    "git commit -anm 'test(j-x): fix'",
    "git commit --no-gpg-sign -m 'test(j-x): fix'",
    "git -c commit.gpgsign=false commit -m 'test(j-x): fix'",
    "command git commit --no-verify -m 'test(j-x): fix'",
    "bash -c \"git commit --no-verify -m 'x'\"",
  ])
    expect((await bash(c)).deny).toMatch(/must not bypass hooks or signing/)
  expect((await bash("git commit -m 'docs(hooks): blocks --no-verify and --no-gpg-sign'")).deny).toBeUndefined()
  expect((await bash("git commit -m 'test(j-checkout): cycle-2 — multi-item variant'")).deny).toBeUndefined()
  expect((await bash("git commit -am 'test(j-x): -n is not the flag here'")).deny).toBeUndefined()
  expect((await bash('git status')).deny).toBeUndefined()
})

test('git commit and gh pr: AI attribution on the whole command surface is denied; human co-authors and prose mentions pass', async ($, on) => {
  const h = engine(on)
  const { bash, orchestrator } = await setup($, h)
  h.write('/tmp/msg', 'test(j-x): fix login\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n')
  h.write('/tmp/body', 'Adds the regression test.\n\nGenerated with [Claude Code](https://claude.com/claude-code)\n')
  h.write('/tmp/clean', 'Adds the regression test for the CSRF fix.\n')
  for (const c of [
    "git commit -m 'test(j-x): fix login' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'",
    'git commit -F - <<EOF\ntest(j-x): fix login\n\n🤖 Generated with [Claude Code](https://claude.ai/code)\nEOF',
    "git commit -m 'test(j-x): fix' -m 'see https://claude.ai/code'",
    'git commit -F /tmp/msg',
  ])
    expect((await bash(c, orchestrator)).deny).toMatch(/AI-attribution in a commit/)
  for (const c of [
    "gh pr create --title 'x' --body 'Body\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>'",
    "gh pr edit 42 --body 'Revised\n\nGenerated with [Claude Code](https://claude.com/claude-code)'",
    "command gh pr create --title 'x' --body 'See https://claude.ai/code for details'",
    'gh pr create --title x --body-file /tmp/body',
    'gh pr create --title x -F /tmp/body',
  ])
    expect((await bash(c, orchestrator)).deny).toMatch(/AI-attribution in a pull request/)
  expect((await bash("git commit -m 'test(j-x): pair fix' -m 'Co-Authored-By: Jane Doe <jane@example.com>'", orchestrator)).deny).toBeUndefined()
  expect((await bash("git commit -m 'docs: fix typo — spell claude correctly in the changelog'", orchestrator)).deny).toBeUndefined()
  expect((await bash("gh pr create --draft --title 'docs: fix typo' --body 'Corrects the spelling of claude in the glossary.'", orchestrator)).deny).toBeUndefined()
  expect((await bash('gh pr create --draft --title x --body-file /tmp/clean', orchestrator)).deny).toBeUndefined()
  expect((await bash('gh pr list', orchestrator)).deny).toBeUndefined()
  // The main loop is never touched: its own commits follow its own harness's rules.
  expect((await $.tool.call({ tool: 'Bash', command: "git commit -m x -m 'Co-Authored-By: Claude <noreply@anthropic.com>'" })).deny).toBeUndefined()
})

test('commit grammar is advice: multi-journey, feat(e2e) and review(...) subjects get a note and still run', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { bash, orchestrator } = await setup($, h)
  for (const [c, says] of [
    ["git commit -m 'test(j-checkout, j-signup): cycle-2 batch'", 'multi-journey'],
    ["git commit -m 'feat(e2e): add checkout coverage'", "'test:' not 'feat:'"],
    ["git commit --message='review(j-checkout): findings'", 'review-tagged'],
  ] as const) {
    expect((await bash(c, orchestrator)).deny).toBeUndefined()
    expect(notes(session, orchestrator).at(-1)).toContain(says)
  }
  const before = notes(session, orchestrator).length
  await bash("git commit -m 'test(j-checkout-regression): lock CSRF fix'", orchestrator)
  await bash("git commit -m 'docs(ledger): j-checkout — 4 probes recorded'", orchestrator)
  expect(notes(session, orchestrator).length).toBe(before)
})

test('k6 run: hard VU and duration ceilings, the allowlist and the production guard deny; in-bound runs pass', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  const config = (c: unknown) => h.write(`${ROOT}/tests/perf/perf-onboarding.config.json`, JSON.stringify(c))
  expect((await bash('k6 run script.js')).deny).toMatch(/perf-onboarding.config.json is missing/)
  config({ targets: { allowlist: ['http://localhost:3000', 'https://staging.example.com'] } })
  const base = '-e PERF_BASE_URL=http://localhost:3000'
  expect((await bash(`k6 run --vus 2000 --duration 30s script.js ${base}`)).deny).toMatch(/hard ceiling of 1000/)
  expect((await bash(`k6 run --vus=1001 script.js ${base}`)).deny).toMatch(/hard ceiling of 1000/)
  expect((await bash(`k6 run -u 5000 script.js ${base}`)).deny).toMatch(/hard ceiling of 1000/)
  expect((await bash(`k6 run --vus 1000 --duration 30s script.js ${base}`)).deny).toBeUndefined()
  expect((await bash(`k6 run --duration 2h script.js ${base}`)).deny).toMatch(/hard ceiling of 3600s/)
  expect((await bash(`k6 run --duration=90m script.js ${base}`)).deny).toMatch(/hard ceiling of 3600s/)
  expect((await bash(`k6 run --duration 3601s script.js ${base}`)).deny).toMatch(/hard ceiling of 3600s/)
  expect((await bash(`k6 run --duration 3600s script.js ${base}`)).deny).toBeUndefined()
  expect((await bash(`k6 run --duration 60m script.js ${base}`)).deny).toBeUndefined()
  expect((await bash('k6 run --vus 50 script.js -e PERF_BASE_URL=https://not-in-list.example.com')).deny).toMatch(/not in targets.allowlist/)
  expect((await bash('k6 run --vus 50 https://other.example.com/script.js')).deny).toMatch(/not in targets.allowlist/)
  expect((await bash('k6 run --vus 50 script.js')).deny).toMatch(/could not determine the load target/)
  expect((await bash('k6 run --vus 50 --duration 5m https://staging.example.com/script.js')).deny).toBeUndefined()
  expect((await bash('PERF_BASE_URL=https://staging.example.com k6 run script.js')).deny).toBeUndefined()
  config({ targets: { allowlist: ['https://staging.example.com', 'https://prod.example.com'] }, production: { origin: 'https://prod.example.com', allowed: false } })
  expect((await bash('k6 run script.js -e PERF_BASE_URL=https://prod.example.com')).deny).toMatch(/production.allowed is not true/)
  expect((await bash('k6 run script.js -e PERF_BASE_URL=https://staging.example.com')).deny).toBeUndefined()
  config({ targets: { allowlist: ['https://prod.example.com'] }, production: { origin: 'https://prod.example.com', allowed: true } })
  expect((await bash('k6 run script.js -e PERF_BASE_URL=https://prod.example.com')).deny).toBeUndefined()
  expect((await bash('echo "k6 run is fast"')).deny).toBeUndefined()
  expect((await bash('cat k6-run-results.json')).deny).toBeUndefined()
})

test('playwright-cli: a missing or malformed slug is rewritten from the agent, a good one is kept, session-agnostic and mentioning commands are untouched', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const session = mock.session(on)
  const { agentId, bash } = await setup($, h, 'inspector')
  const slug = derivedSlug('inspector', agentId)
  await bash('npx playwright-cli open --browser=chromium http://app')
  expect(seen.at(-1)).toBe(`npx playwright-cli -s=${slug} open --browser=chromium http://app`)
  expect(notes(session, agentId).at(-1)).toContain(`it ran as -s=${slug}`)
  await bash('cd app && FOO=1 npx playwright-cli snapshot')
  expect(seen.at(-1)).toBe(`cd app && FOO=1 npx playwright-cli -s=${slug} snapshot`)
  await bash('npx playwright-cli -s=default open http://app')
  expect(seen.at(-1)).toBe(`npx playwright-cli -s=${slug} open http://app`)
  await bash('npx playwright-cli -s fd-x open http://app')
  expect(seen.at(-1)).toBe(`npx playwright-cli -s ${slug} open http://app`)
  await bash('npx playwright-cli -s=composer-j-marketplace-buy-1-c1 open http://app')
  expect(seen.at(-1)).toBe(`npx playwright-cli -s=${slug} open http://app`)
  const noted = notes(session, agentId).length
  for (const c of [
    'npx playwright-cli -s=composer-j-checkout-1-c1 open --browser=chromium http://app',
    'npx playwright-cli close-all',
    'npx playwright-cli list',
    'npx playwright-cli install-browser chromium',
    'npx --no-install playwright-cli --version',
    'echo "playwright-cli is great"',
    "printf 'Run: cd app && playwright-cli open http://x\\n' > notes.md",
    "git commit -m 'docs: x | playwright-cli snapshot needs -s'",
    'cat > notes.md <<EOF\nnpx playwright-cli open http://app\nEOF',
    'command -v playwright-cli',
    'grep -rn playwright-cli hooks/',
    'npm ls @playwright/cli',
  ]) {
    await bash(c)
    expect(seen.at(-1)).toBe(c)
  }
  expect(notes(session, agentId).length).toBe(noted)
  // A nested shell is not rewritten; it is named in a note.
  await bash("sh -c 'npx playwright-cli open http://x'")
  expect(seen.at(-1)).toBe("sh -c 'npx playwright-cli open http://x'")
  expect(notes(session, agentId).at(-1)).toContain('inside a nested shell')
})

test('a shell write to a pipeline state file is advice to use Write or Edit; reads and writes elsewhere say nothing', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator, bash } = await setup($, h)
  for (const c of [
    'cat > tests/e2e/docs/onboarding-status.json <<EOF\n{}\nEOF',
    'echo x >> tests/e2e/docs/journey-map.md',
    'rm tests/e2e/docs/onboarding-status.json',
    'sed -i "" "s/a/b/" tests/e2e/docs/adversarial-findings.md',
    'mv /tmp/forged.json tests/e2e/docs/.phase4-cycle-state.json',
    'tee tests/e2e/docs/coverage-expansion-state.json < /tmp/x',
    'cd tests/e2e/docs && rm flake-quarantine.md',
    "python3 -c 'open(\"tests/perf/docs/perf-onboarding-status.json\",\"w\")'",
  ]) {
    const before = notes(session, orchestrator).length
    expect((await bash(c, orchestrator)).deny).toBeUndefined()
    expect(notes(session, orchestrator).length).toBe(before + 1)
    expect(notes(session, orchestrator).at(-1)).toContain('through the Write or Edit tool')
  }
  const before = notes(session, orchestrator).length
  for (const c of [
    'cat tests/e2e/docs/onboarding-status.json',
    'jq .currentPhase tests/e2e/docs/onboarding-status.json',
    'git diff tests/e2e/docs/journey-map.md',
    'cp tests/e2e/docs/onboarding-status.json /tmp/backup.json',
    'echo "see tests/e2e/docs/journey-map.md" > /tmp/note.txt',
    'git commit -m "fix: rm tests/e2e/docs/onboarding-status.json"',
    'echo hello > /tmp/scratch.txt',
    'ls tests/e2e/docs/onboarding-status.json.bak',
  ])
    await bash(c, orchestrator)
  expect(notes(session, orchestrator).length).toBe(before)
})

test('a line too long to split is refused only when it names a program a deny covers', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  const pad = 'w '.repeat(17000)
  expect((await bash(`echo ${pad}; git push --force`)).deny).toMatch(/too long to judge/)
  expect((await bash(`echo ${pad}`)).deny).toBeUndefined()
  expect(ran(h).length).toBe(0)
})
