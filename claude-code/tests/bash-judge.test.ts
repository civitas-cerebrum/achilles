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

test('a background Bash call from an Achilles loop is refused with the foreground way; the main loop and foreground calls pass', async ($, on) => {
  const h = engine(on)
  const { orchestrator, agentId, bash } = await setup($, h)
  const bg = (as?: string) => $.tool.call({ tool: 'Bash', command: 'npx playwright test tests/e2e/a.spec.ts', run_in_background: true, ...(as ? { agentId: as } : {}) })
  expect((await bg(agentId)).deny).toMatch(/run ends with its turn/)
  expect((await bg(agentId)).deny).toMatch(/foreground/)
  expect((await bg(orchestrator)).deny).toMatch(/run ends with its turn/)
  expect((await bg()).deny).toBeUndefined()
  expect((await bash('npx playwright test tests/e2e/a.spec.ts')).deny).toBeUndefined()
})

test('wdio session: a good slug is kept and recorded, a missing, malformed or taken one is rewritten, snapshot always carries --all', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const session = mock.session(on)
  const { agentId, bash, orchestrator } = await setup($, h, 'inspector')
  const slug = derivedSlug('inspector', agentId)
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:bundleId': 'com.example.shop' }))
  const open = 'open ios --appium-url "$APPIUM_URL" --capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  expect((await bash(`npx wdio session ${open}`)).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} ${open}`)
  expect(notes(session, agentId).at(-1)).toContain(`it ran as -s ${slug}`)
  // A valid brief slug is kept, as playwright-cli keeps one.
  for (const c of [`npx wdio session -s inspect-iphone-1 ${open}`, 'npx wdio session --session inspect-iphone-1 snapshot -i --all --selectors', 'npx @wdio/cli@10.2.0 session -s inspect-iphone-1 close']) {
    expect((await bash(c)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
  }
  for (const [given, why] of [['default', 'collision-prone'], ['ab', 'too short'], ['a-very-long-session-name-that-overflows', 'too long'], ['bad/slug!', 'characters']] as const) {
    await bash(`npx wdio session -s '${given}' snapshot --all`)
    expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
    expect(notes(session, agentId).at(-1)).toContain(why)
  }
  await bash(`npx @wdio/cli session --session=other-slug ${open}`)
  expect(seen.at(-1)).toBe(`npx @wdio/cli session --session=other-slug ${open}`)
  await bash(`npx @wdio/cli session --session=tiny ${open}`)
  expect(seen.at(-1)).toBe(`npx @wdio/cli session -s ${slug} ${open}`)
  await bash('WDIO_SESSION=x wdio session snapshot -i --selectors')
  expect(seen.at(-1)).toBe(`WDIO_SESSION=x wdio session -s ${slug} snapshot --all -i --selectors`)
  await bash(`npx wdio session -s ${slug} tap e3 && npx wdio session -s ${slug} snapshot -i`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} tap e3 && npx wdio session -s ${slug} snapshot --all -i`)
  for (const off of ['--all=false', '--no-all']) {
    await bash(`npx wdio session -s ${slug} snapshot -i ${off}`)
    expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot -i --all`)
  }
  // Another live expert's session name is not taken over.
  const other = await spawnExpert($, h, 'inspector', orchestrator, 'Read `.achilles/runs/x/briefs/o.md` first; write your report to `.achilles/runs/x/reports/o.md`.')
  await bash(`npx wdio session -s inspect-android-1 ${open}`, other)
  await bash('npx wdio session -s inspect-android-1 snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  expect(notes(session, agentId).at(-1)).toContain('another expert')
  // Another live expert's derived slug is taken too, even before it used it.
  await bash(`npx wdio session -s ${derivedSlug('inspector', other)} snapshot --all`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  // A name must start with a letter or digit.
  await bash('npx wdio session -s _hidden-name snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  const noted = notes(session, agentId).length
  for (const c of ['npx wdio session list', 'npx wdio session --help', 'npx wdio session open --help', 'npx wdio --version', 'echo "npx wdio session open ios"', 'echo npx wdio session open ios', 'grep -rn "wdio session" docs/', 'npm ls @wdio/cli']) {
    expect((await bash(c)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
  }
  expect(notes(session, agentId).length).toBe(noted)
})

test('wdio session: the orchestrator opens no device session; it may list sessions and close a stale one by name', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const { orchestrator, bash } = await setup($, h, 'inspector')
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:bundleId': 'com.example.shop' }))
  const open = 'open ios --appium-url "$APPIUM_URL" --capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  for (const c of [`npx wdio session -s preflight-iphone ${open}`, `npx wdio session ${open}`, 'npx wdio session -s preflight-iphone snapshot --all', 'npx wdio session -s inspector-abc123 tap e3', 'npx wdio session doctor'])
    expect((await bash(c, orchestrator)).deny).toMatch(/^achilles: Leave device sessions to the experts/)
  expect((await bash('npx wdio repl ios', orchestrator)).deny).toMatch(/^achilles: Inspect with/)
  expect((await bash('npx wdio session close --all', orchestrator)).deny).toMatch(/^achilles: Close your own session/)
  // Adjacent traffic: listing, closing a session an expert left behind by its name, help and version.
  for (const c of ['npx wdio session list', 'npx wdio session -s inspector-abc123 close', 'npx wdio session --session=inspector-abc123 close', 'npx wdio --version', 'npx wdio session --help', 'npx wdio session open --help']) {
    expect((await bash(c, orchestrator)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
  }
})

test('wdio session: command-form problems are notes and the call runs; more than one session flag, close --all, repl and unreadable forms are refused', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const session = mock.session(on)
  const { agentId, bash, orchestrator } = await setup($, h, 'inspector')
  const slug = derivedSlug('inspector', agentId)
  const said = () => (notes(session, agentId).at(-1) ?? '').replace(/^achilles: /, '')
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:bundleId': 'com.example.shop' }))
  const open = 'open ios --appium-url "$APPIUM_URL" --capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  // A flag before the action: a note, and the call runs as written.
  const early = `npx wdio session -s inspect-iphone-1 --log-level debug ${open}`
  expect((await bash(early)).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(early)
  expect(said()).toMatch(/^Put `--log-level debug` after the action/)
  // A capability flag before the action is still a capability flag.
  expect((await bash(`npx wdio session --udid 0000 ${open}`)).deny).toMatch(/^achilles: Put the value in tests\/capabilities\/<device>\.json.*`--udid` is not part of the inspection form/s)
  expect((await bash(`npx wdio session --foo bar open ios --capabilities '{"platformName":"iOS"}'`)).deny).toMatch(/inline JSON/)
  // An unknown action: a note; the CLI refuses it itself.
  expect((await bash('npx wdio session -s inspect-iphone-1 frobnicate e3')).deny).toBeUndefined()
  expect(seen.at(-1)).toBe('npx wdio session -s inspect-iphone-1 frobnicate e3')
  expect(said()).toMatch(/^Check the action against `npx wdio session --help`: 'frobnicate' is not a wdio session action/)
  expect((await bash(`npx wdio session --json -q --timeout 20000 -s inspect-iphone-1 ${open}`)).deny).toBeUndefined()
  // More than one session flag: the judge cannot tell which session the call reaches, so it cannot keep it off another expert's.
  expect((await bash(`npx wdio session -s inspect-iphone-1 -s other-iphone ${open}`)).deny).toMatch(/^achilles: Pass one -s <slug>.*more than one session flag/s)
  expect((await bash(`npx wdio session -sinspect-iphone-1 --session other-iphone ${open}`)).deny).toMatch(/more than one session flag/)
  // The same valid name given twice collapses to one flag.
  expect((await bash(`npx wdio session -s inspect-iphone-1 -s inspect-iphone-1 ${open}`)).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(`npx wdio session -s inspect-iphone-1 ${open}`)
  expect(said()).toContain('it ran with one session flag')
  expect((await bash('npx wdio session --session=inspect-iphone-1 snapshot --all -s inspect-iphone-1')).deny).toBeUndefined()
  expect(seen.at(-1)).toBe('npx wdio session --session=inspect-iphone-1 snapshot --all')
  // The same name twice that is not this agent's to use: merged, then rewritten to the agent's own name.
  expect((await bash(`npx wdio session -s ab -s ab ${open}`)).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} ${open}`)
  expect(said()).toContain(`it ran as -s ${slug}`)
  expect((await bash('npx wdio session -s default snapshot --all --session=default')).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  // Different names stay refused, whoever holds them.
  expect((await bash(`npx wdio session -s ab -s cd ${open}`)).deny).toMatch(/more than one session flag/)
  // `session` as an argument of another wdio command is not a wdio session call.
  for (const c of ['npx wdio run wdio.conf.ts --suite session', 'npx wdio run wdio.conf.ts --spec tests/session.spec.ts', 'npx wdio run ./wdio.conf.ts --mochaOpts.grep session', 'npm exec wdio -- run wdio.conf.ts --suite session']) {
    expect((await bash(c)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
  }
  // An option before the subcommand does not hide it.
  expect((await bash(`npx wdio --log-level debug session ${open}`)).deny).toMatch(/Run it as `npx wdio session/)
  await bash('npx wdio session -sother snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  // Other entry points to the same CLI.
  expect((await bash(`npx -p @wdio/cli wdio session ${open} --udid 0000`)).deny).toMatch(/not part of the inspection form/)
  expect((await bash(`node node_modules/@wdio/cli/bin/wdio.js session ${open} --udid 0000`)).deny).toMatch(/not part of the inspection form/)
  await bash(`node node_modules/@wdio/cli/bin/wdio.js session ${open}`)
  expect(seen.at(-1)).toBe(`node node_modules/@wdio/cli/bin/wdio.js session -s ${slug} ${open}`)
  expect((await bash('npx wdio repl ios')).deny).toMatch(/^achilles: Inspect with .*--bundle-id <id> \| --package <id>.*wdio repl/s)
  for (const c of [`npm exec wdio -- session ${open}`, `yarn wdio session ${open}`, `pnpm wdio session ${open}`, `node -r ./hook.js node_modules/@wdio/cli/bin/wdio.js session ${open}`, `echo x | xargs npx wdio session ${open}`])
    expect((await bash(c)).deny).toMatch(/^achilles: Run it as `npx wdio session/)
  // yarn exec / pnpm exec are npx: judged like it.
  await bash(`yarn exec wdio session ${open}`)
  expect(seen.at(-1)).toBe(`yarn exec wdio session -s ${slug} ${open}`)
  await bash(`pnpm exec -- wdio session ${open}`)
  expect(seen.at(-1)).toBe(`pnpm exec -- wdio session -s ${slug} ${open}`)
  // After a free-text action only the exact session flag forms count.
  await bash(`npx wdio session -s ${slug} fill e3 -secret-value`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} fill e3 -secret-value`)
  expect((await bash(`npx wdio session -s ${slug} fill e3 --session=other-iphone`)).deny).toMatch(/more than one session flag/)
  // That holds after every action, not only the free-text ones.
  await bash(`npx wdio session -s ${slug} click e3 -sx`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} click e3 -sx`)
  // find that only lists is a reader; find that runs something is not.
  expect((await bash('find node_modules -name wdio -o -name session')).deny).toBeUndefined()
  expect((await bash(`find . -name wdio.js -exec node {} session ${open} ;`)).deny).toMatch(/Run it as `npx wdio session/)
  expect((await bash('npx wdio session close --all')).deny).toMatch(/^achilles: Close your own session with `npx wdio session -s <slug> close`.*every session/s)
  expect((await bash(`npx wdio session -s ${slug} close`)).deny).toBeUndefined()
  // A nested shell is judged the same way. A name or --all it would need cannot be rewritten there, so it is a note;
  // another expert's name stays refused.
  expect((await bash(`sh -c 'npx wdio session -s inspect-iphone-1 ${open} --udid 1'`)).deny).toMatch(/not part of the inspection form/)
  const nested = `sh -c 'npx wdio session ${open}'`
  expect((await bash(nested)).deny).toBeUndefined()
  expect(seen.at(-1)).toBe(nested)
  expect(said()).toContain(`-s ${slug}`)
  expect((await bash("sh -c 'npx wdio session -s inspect-iphone-1 snapshot'")).deny).toBeUndefined()
  expect(said()).toContain('--all')
  expect((await bash("sh -c 'npx wdio session -s inspect-iphone-1 snapshot --all'")).deny).toBeUndefined()
  const other = await spawnExpert($, h, 'inspector', orchestrator, 'Read `.achilles/runs/x/briefs/o.md` first; write your report to `.achilles/runs/x/reports/o.md`.')
  await bash(`npx wdio session -s inspect-android-1 ${open}`, other)
  expect((await bash("sh -c 'npx wdio session -s inspect-android-1 snapshot --all'")).deny).toMatch(/^achilles: Use your own session name \(-s inspector-[0-9a-f]{6}\).*another expert/s)
})

test('wdio session open: capability and server flags, inline capabilities and an idle timeout past the cap are refused; every other open problem is a note naming the fix', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const session = mock.session(on)
  const { agentId, bash } = await setup($, h, 'inspector')
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:bundleId': 'com.example.shop' }))
  h.write(`${ROOT}/tests/capabilities/pixel.json`, JSON.stringify({ platformName: 'Android', 'appium:automationName': 'UiAutomator2', 'appium:appPackage': 'com.example.shop' }))
  h.write(`${ROOT}/tests/capabilities/build.json`, JSON.stringify({ platformName: 'iOS', 'appium:app': './build/Shop.ipa' }))
  h.write(`${ROOT}/tests/capabilities/noapp.json`, JSON.stringify({ platformName: 'iOS', 'appium:udid': '00000000-0000000000000000' }))
  h.write(`${ROOT}/tests/capabilities/noname.json`, JSON.stringify({ 'appium:automationName': 'XCUITest' }))
  const url = '--appium-url "$APPIUM_URL"'
  const iphone = '--capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  const s = 'npx wdio session -s inspect-iphone-1'
  for (const c of [
    `${s} open ios ${url} ${iphone}`,
    `${s} open ios --appium-url http://127.0.0.1:4723/wd/hub --capabilities=./tests/capabilities/iphone.json --bundle-id=com.example.shop`,
    `${s} open ios --appium-url=\${APPIUM_URL} ${iphone} --replace --idle-timeout 10m`,
    `${s} open ios ${url} ${iphone} --idle-timeout 30m`,
    `${s} open ios ${url} --capabilities ${ROOT}/tests/capabilities/iphone.json --bundle-id com.example.shop`,
    `${s} open android ${url} --capabilities tests/capabilities/pixel.json --package com.example.shop`,
    `${s} open ios ${url} --capabilities tests/capabilities/build.json --app ./build/Shop.ipa`,
  ]) {
    const n = notes(session, agentId).length
    expect((await bash(c)).deny).toBeUndefined()
    expect(notes(session, agentId).length).toBe(n)
  }
  // Denied: what could reset or retarget a shared device, or hold it past the cap.
  expect((await bash(`${s} open ios ${url} --capabilities '{"platformName":"iOS"}'`)).deny).toMatch(/^achilles: Pass the capabilities file.*inline JSON/s)
  for (const flag of ['--udid 00000000-0000000000000000', '--device iPhone', '--platform-version 17', '--no-reset', '--full-reset', '--orientation landscape', '--hostname h', '--port 4723', '--path /wd/hub', '--provider browserstack', '--device-name x', '--sauce-key k', '--protocol https', '--attach 9222', '--os Windows', '--os-version 11', '--region eu', '--tunnel', '--tunnel external', '--tunnel-name t1', '--browser chrome'])
    expect((await bash(`${s} open ios ${url} ${iphone} ${flag}`)).deny).toMatch(/^achilles: Put the value in tests\/capabilities\/<device>\.json.*not part of the inspection form/s)
  // Option names are read as the CLI's parser reads them: camelCase, snake_case and upper case are the kebab-case flag.
  for (const spelling of ['--idleTimeout 0', '--idleTimeout=0', '--idle_timeout 0', '--IDLE-TIMEOUT 0', '--Idle-Timeout=2h'])
    expect((await bash(`${s} open ios ${url} ${iphone} ${spelling}`)).deny).toMatch(/^achilles: Open with --idle-timeout 30m or less/)
  for (const spelling of ['--noReset', '--fullReset', '--platformVersion 17', '--UDID 0000', '--device_name x'])
    expect((await bash(`${s} open ios ${url} ${iphone} ${spelling}`)).deny).toMatch(/^achilles: Put the value in tests\/capabilities\/<device>\.json/)
  // An unknown short flag may alias a capability option: refused, with the long form to use.
  for (const short of ['-u 0000', '-d iPhone', '-r', '-u=0000'])
    expect((await bash(`${s} open ios ${url} ${iphone} ${short}`)).deny).toMatch(/^achilles: Use a long flag listed by `npx wdio session open --help`, or put the value in tests\/capabilities\/<device>\.json.*`-[udr]`/s)
  expect((await bash(`npx wdio session -u 0000 open ios ${url} ${iphone}`)).deny).toMatch(/^achilles: Use a long flag listed by `npx wdio session open --help`.*`-u`/s)
  // Adjacent traffic: -q is a known short flag; the allowed flags in other spellings pass silently.
  for (const c of [
    `${s} open ios ${url} ${iphone} -q`,
    `${s} open ios ${url} --capabilities tests/capabilities/iphone.json --bundleId com.example.shop`,
    `${s} open ios ${url} --capabilities tests/capabilities/iphone.json --bundle_id=com.example.shop --idleTimeout 10m`,
    `${s} open ios ${url} ${iphone} --logLevel debug --launchTimeout 60000`,
    `${s} open ios --appiumUrl "$APPIUM_URL" ${iphone}`,
  ]) {
    const n = notes(session, agentId).length
    expect((await bash(c)).deny).toBeUndefined()
    expect(notes(session, agentId).length).toBe(n)
  }
  expect((await bash(`${s} open ios ${url} --capabilities tests/capabilities/iphone.json --bundleId com.example.other`)).deny).toBeUndefined()
  expect(notes(session, agentId).at(-1)).toMatch(/^achilles: Use --bundle-id com\.example\.shop.*does not match/s)
  for (const idle of ['2h', '31m', '0', '7200s', 'soon'])
    expect((await bash(`${s} open ios ${url} ${iphone} --idle-timeout ${idle}`)).deny).toMatch(/^achilles: Open with --idle-timeout 30m or less/)
  // Notes: the call runs as written, and the note leads with the fix.
  const advised = async (c: string, says: RegExp) => {
    expect((await bash(c)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
    expect(notes(session, agentId).at(-1)?.replace(/^achilles: /, '')).toMatch(says)
  }
  const bare = '--capabilities tests/capabilities/iphone.json'
  await advised(`${s} open ios ${url}`, /^Open with --capabilities tests\/capabilities\/<device>\.json/)
  await advised(`${s} open ios ${url} --capabilities caps.ios.json`, /^Use a capabilities file under tests\/capabilities\//)
  await advised(`${s} open ios ${url} --capabilities "$CAPS"`, /^Use a capabilities file under tests\/capabilities\//)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/missing.json --bundle-id x`, /^Write tests\/capabilities\/missing\.json first/)
  await advised(`${s} open ios ${iphone}`, /^Name the server with --appium-url/)
  await advised(`${s} open ios --appium-url localhost:4723 ${iphone}`, /^Name the server with --appium-url/)
  await advised(`${s} open ios ${url} ${bare}`, /^Add --bundle-id com\.example\.shop.*exits 2/s)
  await advised(`${s} open ios ${url} ${bare} --bundle-id com.example.other`, /^Use --bundle-id com\.example\.shop.*does not match/s)
  await advised(`${s} open ios ${url} ${bare} --package com.example.shop`, /^Drop --package: it does not apply to ios/)
  await advised(`${s} open ios ${url} ${iphone} --app ./x.ipa`, /^Open with --bundle-id com\.example\.shop, not --app/)
  await advised(`${s} open android ${url} --capabilities tests/capabilities/pixel.json`, /^Add --package com\.example\.shop/)
  await advised(`${s} open android ${url} --capabilities tests/capabilities/pixel.json --package com.other`, /^Use --package com\.example\.shop/)
  await advised(`${s} open android ${url} --capabilities tests/capabilities/pixel.json --package com.example.shop --activity .Main`, /^Put appium:appActivity in tests\/capabilities\/pixel\.json/)
  h.write(`${ROOT}/tests/capabilities/pixel-main.json`, JSON.stringify({ platformName: 'Android', 'appium:appPackage': 'com.example.shop', 'appium:appActivity': '.Main' }))
  const n = notes(session, agentId).length
  expect((await bash(`${s} open android ${url} --capabilities tests/capabilities/pixel-main.json --package com.example.shop --activity .Main`)).deny).toBeUndefined()
  expect(notes(session, agentId).length).toBe(n)
  await advised(`${s} open android ${url} --capabilities tests/capabilities/pixel-main.json --package com.example.shop --activity .Other`, /^Put appium:appActivity in/)
  await advised(`${s} open ios ${url} ${iphone} --headed`, /^Check `npx wdio session open --help` and drop `--headed`: it is not part of the inspection form/)
  await advised(`${s} open ios ${url} ${iphone} --log-format json`, /^Check `npx wdio session open --help` and drop `--log-format`/)
  // Browser-, desktop-app- and label-only options of @wdio/session 10.2.0 open touch no device: a note, and the call runs.
  for (const flag of ['--binary /usr/bin/chromium', '--profile ./profile', '--arg=--disable-gpu', '--arg a b', '--headless', '--viewport 1280x720', '--browser-version 120', '--no-bidi', '--app-arg=--no-sandbox', '--chromedriver ./cd', '--electron-version 30', '--project shop', '--build b1', '--name smoke'])
    await advised(`${s} open ios ${url} ${iphone} ${flag}`, new RegExp(`^Check \`npx wdio session open --help\` and drop \`${flag.split(/[ =]/)[0]}\``))
  // A dash-leading word is never a value (the CLI's parser reads it as the next flag): a note flag
  // or a known value flag followed by a capability flag does not hide it.
  for (const hidden of ['--profile --udid X', '--arg --no-reset', '--viewport --full-reset', '--name --device=iPhone', '--build --hostname evil', '--arg a b --udid X', '--app-arg x --port 1', '--log-level --udid X', '--capabilities --udid X'])
    expect((await bash(`${s} open ios ${url} ${iphone} ${hidden}`)).deny).toMatch(/^achilles: Put the value in tests\/capabilities\/<device>\.json/)
  await advised(`${s} open ios ${url} ${iphone} --arg --x`, /drop `--x`/)
  // An array option takes every following word, as the parser does: no extra-argument note.
  await advised(`${s} open ios ${url} ${iphone} --arg one two`, /drop `--arg`/)
  // A string-valued note flag takes its value, which is never read as an extra positional.
  await advised(`${s} open ios --profile p ${url} ${iphone}`, /drop `--profile`/)
  expect(notes(session, agentId).at(-1)).not.toMatch(/extra argument/)
  await advised(`${s} open ios ${url} ${iphone} --activity .Main`, /^Drop --activity: it does not apply to ios/)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/build.json`, /^Add --app \.\/build\/Shop\.ipa/)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/build.json --app ./other.ipa`, /^Use --app \.\/build\/Shop\.ipa.*not --app \.\/other\.ipa/s)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/build.json --bundle-id com.example.shop`, /^Open with --app \.\/build\/Shop\.ipa, not --bundle-id/)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/noapp.json --bundle-id com.example.shop`, /^Name the app in tests\/capabilities\/noapp\.json/)
  await advised(`${s} open chrome http://app`, /^Open android or ios.*playwright-cli/s)
  await advised(`${s} open macos ${url} ${iphone}`, /^Inspect on android or ios: platform "macos" is declared but not implemented yet/)
  await advised(`${s} open ios com.example.shop ${url} ${iphone}`, /^Drop the extra argument \(com\.example\.shop\)/)
  await advised(`${s} open android ${url} ${iphone}`, /^Open the platform tests\/capabilities\/iphone\.json names \(ios\).*platformName "iOS"/s)
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/noname.json --bundle-id x`, /^Add platformName to tests\/capabilities\/noname\.json/)
  for (const [name, doc] of [['w3c', { alwaysMatch: { platformName: 'iOS' }, firstMatch: [{}] }], ['first', { firstMatch: [{ platformName: 'iOS' }] }], ['wrapped', { capabilities: { platformName: 'iOS' } }], ['null', null], ['list', [{ platformName: 'iOS' }]], ['text', 'iOS']] as const) {
    h.write(`${ROOT}/tests/capabilities/${name}.json`, JSON.stringify(doc))
    await advised(`${s} open ios ${url} --capabilities tests/capabilities/${name}.json --bundle-id com.example.shop`, /^Make tests\/capabilities\/\w+\.json a flat JSON object: top-level keys, no alwaysMatch\/firstMatch wrapper/)
  }
  h.write(`${ROOT}/tests/capabilities/broken.json`, '{ not json')
  await advised(`${s} open ios ${url} --capabilities tests/capabilities/broken.json --bundle-id com.example.shop`, /^Fix tests\/capabilities\/broken\.json: it is not JSON/)
})

test('platform runs key only off E2E_PLATFORM, E2E_CAPABILITIES and the platform config; a run outside the form gets a note and runs; web runs with any PLATFORM value pass silently', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { agentId, bash } = await setup($, h)
  const silent = async (c: string) => {
    const n = notes(session, agentId).length
    expect((await bash(c)).deny).toBeUndefined()
    expect(notes(session, agentId).slice(n).filter(x => /E2E_|platform/.test(x))).toEqual([])
  }
  const advised = async (c: string, says: RegExp) => {
    expect((await bash(c)).deny).toBeUndefined()
    expect(notes(session, agentId).at(-1)?.replace(/^achilles: /, '')).toMatch(says)
  }
  const cfg = '-c playwright.platform.config.ts'
  // Web runs: an ambient or unrelated PLATFORM / CAPABILITIES is not ours.
  h.write(`${ROOT}/package.json`, JSON.stringify({ scripts: { test: 'playwright test', 'test:e2e': 'playwright test -c playwright.config.ts' } }))
  for (const c of [
    'npx playwright test tests/e2e/login.spec.ts',
    'PLATFORM=linux npx playwright test',
    'PLATFORM=linux npm test',
    'PLATFORM=linux npm run test:e2e',
    'export PLATFORM=staging && npm test',
    'Platform=x64 npx playwright test',
    'PLATFORM=ios CAPABILITIES=caps/iphone.json npx playwright test',
    'E2E_PLATFORM=web npx playwright test tests/e2e/login.spec.ts',
    'E2E_PLATFORM=web npm test',
  ])
    await silent(c)
  // Platform runs in the one form.
  for (const c of [
    `E2E_PLATFORM=ios E2E_CAPABILITIES=tests/capabilities/iphone.json APPIUM_URL=http://127.0.0.1:4723/wd/hub npx playwright test ${cfg}`,
    'E2E_PLATFORM=android E2E_CAPABILITIES=./tests/capabilities/pixel.json npx playwright test --config=playwright.platform.config.ts tests/platform/login.spec.ts',
    `export E2E_PLATFORM=ios E2E_CAPABILITIES=tests/capabilities/iphone.json && npx playwright test ${cfg}`,
    `npx playwright test ${cfg} --list`,
  ])
    await silent(c)
  // Outside the form: a note leading with the fix; the run goes ahead.
  await advised(`E2E_PLATFORM=ios E2E_CAPABILITIES=caps/iphone.json npx playwright test ${cfg}`, /^Name a file under tests\/capabilities\/ with E2E_CAPABILITIES: caps\/iphone\.json is not one/)
  await advised(`E2E_PLATFORM=ios E2E_CAPABILITIES=$HOME/iphone.json npx playwright test ${cfg}`, /^Name a file under tests\/capabilities\//)
  await advised(`E2E_PLATFORM=ios npx playwright test ${cfg}`, /^Name the device with E2E_CAPABILITIES=tests\/capabilities\/<device>\.json/)
  await advised(`E2E_CAPABILITIES=tests/capabilities/iphone.json npx playwright test ${cfg}`, /^Set E2E_PLATFORM=<android\|ios>/)
  await advised(`npx playwright test ${cfg}`, /^Set E2E_PLATFORM=<android\|ios>/)
  await advised(`E2E_PLATFORM=web E2E_CAPABILITIES=tests/capabilities/iphone.json npx playwright test ${cfg}`, /^Set E2E_PLATFORM to android or ios/)
  await advised(`E2E_PLATFORM=windows E2E_CAPABILITIES=tests/capabilities/win.json npx playwright test ${cfg}`, /^Run on android or ios: E2E_PLATFORM=windows is declared but not implemented yet/)
  await advised('E2E_PLATFORM=ios E2E_CAPABILITIES=tests/capabilities/iphone.json npx playwright test tests/platform/a.spec.ts', /^Run it with -c playwright\.platform\.config\.ts/)
  for (const c of ['E2E_PLATFORM=ios npx playwright test', 'E2E_PLATFORM=android npm test']) await advised(c, /playwright\.platform\.config\.ts/)
  h.write(`${ROOT}/package.json`, JSON.stringify({ scripts: { 'test:platform': 'playwright test -c playwright.platform.config.ts', test: 'playwright test -c playwright.platform.config.ts' } }))
  for (const run of ['npm run test:platform', 'pnpm test:platform', 'yarn test:platform', 'pnpm run test:platform', 'npm test', 'npm t', 'yarn test', 'npm --silent test', 'npm -s run test:platform', 'yarn -s test:platform', 'npm --prefix app test', 'npm -w app run test:platform', 'yarn --cwd app test:platform', 'pnpm -C app test:platform', 'pnpm --filter app test:platform', 'npm --loglevel silent test']) {
    await silent(`E2E_PLATFORM=ios E2E_CAPABILITIES=tests/capabilities/iphone.json ${run}`)
    await advised(`E2E_PLATFORM=ios E2E_CAPABILITIES=/tmp/x.json ${run}`, /tests\/capabilities\//)
  }
  await silent('pnpm install')
})

test('a line too long to split that names wdio is refused', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  expect((await bash(`echo ${'w '.repeat(17000)}; npx wdio session open ios`)).deny).toMatch(/too long to judge/)
})
