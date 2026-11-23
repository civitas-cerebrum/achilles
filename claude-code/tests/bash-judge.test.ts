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
  // Another live expert's derived slug is taken too, even before it used it; so is a name the orchestrator holds.
  await bash(`npx wdio session -s ${derivedSlug('inspector', other)} snapshot --all`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  await bash('npx wdio session -s preflight-iphone snapshot --all', orchestrator)
  expect(seen.at(-1)).toBe('npx wdio session -s preflight-iphone snapshot --all')
  await bash('npx wdio session -s preflight-iphone snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  expect(notes(session, agentId).at(-1)).toContain('the orchestrator')
  // A name must start with a letter or digit.
  await bash('npx wdio session -s _hidden-name snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  // An expert whose own derived slug the orchestrator already holds gets a different one.
  const nextId = `inspector-${Number(other.split('-')[1]) + 1}`
  await bash(`npx wdio session -s ${derivedSlug('inspector', nextId)} snapshot --all`, orchestrator)
  const late = await spawnExpert($, h, 'inspector', orchestrator, 'Read `.achilles/runs/x/briefs/l.md` first; write your report to `.achilles/runs/x/reports/l.md`.')
  expect(late).toBe(nextId)
  await bash('npx wdio session snapshot --all', late)
  const lateName = /-s (\S+) snapshot/.exec(seen.at(-1)!)![1]!
  expect(lateName).not.toBe(derivedSlug('inspector', late))
  expect(lateName).toMatch(/^inspector-[0-9a-f]{6}$/)
  // The orchestrator may close a session an expert left behind by its name.
  await bash('npx wdio session -s inspector-abc123 close', orchestrator)
  expect(seen.at(-1)).toBe('npx wdio session -s inspector-abc123 close')
  const noted = notes(session, agentId).length
  for (const c of ['npx wdio session list', 'npx wdio session --help', 'npx wdio session open --help', 'npx wdio --version', 'echo "npx wdio session open ios"', 'echo npx wdio session open ios', 'grep -rn "wdio session" docs/', 'npm ls @wdio/cli']) {
    expect((await bash(c)).deny).toBeUndefined()
    expect(seen.at(-1)).toBe(c)
  }
  expect(notes(session, agentId).length).toBe(noted)
})

test('wdio session: the action comes from the known list, only global flags precede it, one session flag, other wdio entry points are judged too', async ($, on) => {
  const seen: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => (seen.push(e.command), { result: { ok: true } }))
  const h = engine(on)
  const { agentId, bash } = await setup($, h, 'inspector')
  const slug = derivedSlug('inspector', agentId)
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:bundleId': 'com.example.shop' }))
  const open = 'open ios --appium-url "$APPIUM_URL" --capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  expect((await bash(`npx wdio session --foo bar open ios --capabilities '{"platformName":"iOS"}'`)).deny).toMatch(/--foo/)
  expect((await bash(`npx wdio session --log-level debug ${open}`)).deny).toMatch(/--log-level/)
  expect((await bash('npx wdio session frobnicate e3')).deny).toMatch(/not a wdio session action/)
  expect((await bash(`npx wdio session -s inspect-iphone-1 -s other-iphone ${open}`)).deny).toMatch(/more than one session flag/)
  expect((await bash(`npx wdio session -sinspect-iphone-1 --session other-iphone ${open}`)).deny).toMatch(/more than one session flag/)
  expect((await bash(`npx wdio session --json -q --timeout 20000 -s inspect-iphone-1 ${open}`)).deny).toBeUndefined()
  await bash('npx wdio session -sother snapshot --all')
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} snapshot --all`)
  // Other entry points to the same CLI.
  expect((await bash(`npx -p @wdio/cli wdio session ${open} --udid 0000`)).deny).toMatch(/not part of the inspection form/)
  expect((await bash(`node node_modules/@wdio/cli/bin/wdio.js session ${open} --udid 0000`)).deny).toMatch(/not part of the inspection form/)
  await bash(`node node_modules/@wdio/cli/bin/wdio.js session ${open}`)
  expect(seen.at(-1)).toBe(`node node_modules/@wdio/cli/bin/wdio.js session -s ${slug} ${open}`)
  expect((await bash('npx wdio repl ios')).deny).toMatch(/repl/)
  for (const c of [`npm exec wdio -- session ${open}`, `yarn wdio session ${open}`, `pnpm wdio session ${open}`,`node -r ./hook.js node_modules/@wdio/cli/bin/wdio.js session ${open}`, `echo x | xargs npx wdio session ${open}`])
    expect((await bash(c)).deny).toMatch(/run it as `npx wdio session/)
  // yarn exec / pnpm exec are npx: judged like it.
  await bash(`yarn exec wdio session ${open}`)
  expect(seen.at(-1)).toBe(`yarn exec wdio session -s ${slug} ${open}`)
  await bash(`pnpm exec -- wdio session ${open}`)
  expect(seen.at(-1)).toBe(`pnpm exec -- wdio session -s ${slug} ${open}`)
  // After a free-text action only the exact session flag forms count.
  await bash(`npx wdio session -s ${slug} fill e3 -secret-value`)
  expect(seen.at(-1)).toBe(`npx wdio session -s ${slug} fill e3 -secret-value`)
  expect((await bash(`npx wdio session -s ${slug} fill e3 --session=other-iphone`)).deny).toMatch(/more than one session flag/)
  expect((await bash('npx wdio session close --all')).deny).toMatch(/every session/)
  // A nested shell is judged the same way; a name it would need rewritten is refused, since it cannot be rewritten there.
  expect((await bash(`sh -c 'npx wdio session -s inspect-iphone-1 ${open} --udid 1'`)).deny).toMatch(/not part of the inspection form/)
  expect((await bash(`sh -c 'npx wdio session ${open}'`)).deny).toContain(`-s ${slug}`)
  expect((await bash("sh -c 'npx wdio session -s inspect-iphone-1 snapshot --all'")).deny).toBeUndefined()
})

test('wdio session open: capabilities only from tests/capabilities/*.json, the server only from --appium-url, no capability flags, the platform the file names, and the app id the file names repeated as --bundle-id / --package / --app', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h, 'inspector')
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS', 'appium:bundleId': 'com.example.shop' }))
  h.write(`${ROOT}/tests/capabilities/pixel.json`, JSON.stringify({ platformName: 'Android', 'appium:automationName': 'UiAutomator2', 'appium:appPackage': 'com.example.shop' }))
  h.write(`${ROOT}/tests/capabilities/build.json`, JSON.stringify({ platformName: 'iOS', 'appium:app': './build/Shop.ipa' }))
  h.write(`${ROOT}/tests/capabilities/noapp.json`, JSON.stringify({ platformName: 'iOS', 'appium:udid': '00000000-0000000000000000' }))
  h.write(`${ROOT}/tests/capabilities/noname.json`, JSON.stringify({ 'appium:automationName': 'XCUITest' }))
  const url = '--appium-url "$APPIUM_URL"'
  const iphone = '--capabilities tests/capabilities/iphone.json --bundle-id com.example.shop'
  for (const c of [
    `npx wdio session open ios ${url} ${iphone}`,
    'npx wdio session open ios --appium-url http://127.0.0.1:4723/wd/hub --capabilities=./tests/capabilities/iphone.json --bundle-id=com.example.shop',
    `npx wdio session open ios --appium-url=\${APPIUM_URL} ${iphone} --replace --idle-timeout 10m`,
    `npx wdio session open ios ${url} ${iphone} --idle-timeout 30m`,
    `npx wdio session open android ${url} --capabilities tests/capabilities/pixel.json --package com.example.shop --activity .Main`,
    `npx wdio session open ios ${url} --capabilities ${ROOT}/tests/capabilities/iphone.json --bundle-id com.example.shop`,
    `npx wdio session open android ${url} --capabilities tests/capabilities/pixel.json --package com.example.shop`,
    `npx wdio session open ios ${url} --capabilities tests/capabilities/build.json --app ./build/Shop.ipa`,
  ])
    expect((await bash(c)).deny).toBeUndefined()
  expect((await bash(`npx wdio session open ios ${url}`)).deny).toMatch(/--capabilities tests\/capabilities\/<device>\.json/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities '{"platformName":"iOS"}'`)).deny).toMatch(/inline JSON/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities caps.ios.json`)).deny).toMatch(/not a file under tests\/capabilities/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities "$CAPS"`)).deny).toMatch(/not a file under tests\/capabilities/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/missing.json`)).deny).toMatch(/does not exist/)
  expect((await bash(`npx wdio session open ios ${iphone}`)).deny).toMatch(/--appium-url/)
  expect((await bash(`npx wdio session open ios --appium-url localhost:4723 ${iphone}`)).deny).toMatch(/--appium-url/)
  for (const flag of ['--udid 00000000-0000000000000000', '--device iPhone', '--platform-version 17', '--no-reset', '--full-reset', '--orientation landscape', '--hostname h', '--port 4723', '--path /wd/hub', '--provider browserstack', '--headed'])
    expect((await bash(`npx wdio session open ios ${url} ${iphone} ${flag}`)).deny).toMatch(/not part of the inspection form/)
  // The CLI checks the app flag before it reads the file, so the form always repeats the file's app id.
  const bare = '--capabilities tests/capabilities/iphone.json'
  expect((await bash(`npx wdio session open ios ${url} ${bare}`)).deny).toMatch(/needs --bundle-id com\.example\.shop/)
  expect((await bash(`npx wdio session open ios ${url} ${bare} --bundle-id com.example.other`)).deny).toMatch(/does not match .* com\.example\.shop/)
  expect((await bash(`npx wdio session open ios ${url} ${bare} --package com.example.shop`)).deny).toMatch(/--package does not apply to ios/)
  expect((await bash(`npx wdio session open ios ${url} ${iphone} --app ./x.ipa`)).deny).toMatch(/not --app/)
  expect((await bash(`npx wdio session open android ${url} --capabilities tests/capabilities/pixel.json`)).deny).toMatch(/needs --package com\.example\.shop/)
  expect((await bash(`npx wdio session open android ${url} --capabilities tests/capabilities/pixel.json --package com.other`)).deny).toMatch(/does not match/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/build.json`)).deny).toMatch(/needs --app \.\/build\/Shop\.ipa/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/build.json --app ./other.ipa`)).deny).toMatch(/not --app \.\/other\.ipa/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/build.json --bundle-id com.example.shop`)).deny).toMatch(/appium:app/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/noapp.json --bundle-id com.example.shop`)).deny).toMatch(/must name the app/)
  expect((await bash('npx wdio session open chrome http://app')).deny).toMatch(/playwright-cli/)
  expect((await bash(`npx wdio session open macos ${url} ${iphone}`)).deny).toMatch(/not implemented yet/)
  expect((await bash(`npx wdio session open ios com.example.shop ${url} ${iphone}`)).deny).toMatch(/positional/)
  expect((await bash(`npx wdio session open android ${url} ${iphone}`)).deny).toMatch(/platformName "iOS"/)
  expect((await bash(`npx wdio session open ios ${url} --capabilities tests/capabilities/noname.json`)).deny).toMatch(/no platformName/)
  for (const idle of ['2h', '31m', '0', '7200s'])
    expect((await bash(`npx wdio session open ios ${url} ${iphone} --idle-timeout ${idle}`)).deny).toMatch(/idle-timeout/)
})

test('platform runs: PLATFORM, CAPABILITIES under tests/capabilities/ and the platform config are the only form, through npm, pnpm and yarn scripts too; web runs and --list are untouched', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  const cfg = '-c playwright.platform.config.ts'
  for (const c of [
    `PLATFORM=ios CAPABILITIES=tests/capabilities/iphone.json APPIUM_URL=http://127.0.0.1:4723/wd/hub npx playwright test ${cfg}`,
    'PLATFORM=android CAPABILITIES=./tests/capabilities/pixel.json npx playwright test --config=playwright.platform.config.ts tests/platform/login.spec.ts',
    `export PLATFORM=ios CAPABILITIES=tests/capabilities/iphone.json && npx playwright test ${cfg}`,
    `npx playwright test ${cfg} --list`,
    'npx playwright test tests/e2e/login.spec.ts',
    'PLATFORM=web npx playwright test tests/e2e/login.spec.ts',
  ])
    expect((await bash(c)).deny).toBeUndefined()
  expect((await bash(`PLATFORM=ios CAPABILITIES=caps/iphone.json npx playwright test ${cfg}`)).deny).toMatch(/CAPABILITIES=.* is not a file under tests\/capabilities\//)
  expect((await bash(`PLATFORM=ios CAPABILITIES=$HOME/iphone.json npx playwright test ${cfg}`)).deny).toMatch(/CAPABILITIES=.* is not a file under tests\/capabilities\//)
  expect((await bash(`PLATFORM=ios npx playwright test ${cfg}`)).deny).toMatch(/CAPABILITIES=tests\/capabilities\/<device>\.json/)
  expect((await bash(`CAPABILITIES=tests/capabilities/iphone.json npx playwright test ${cfg}`)).deny).toMatch(/PLATFORM=/)
  expect((await bash(`PLATFORM=mobile CAPABILITIES=tests/capabilities/iphone.json npx playwright test ${cfg}`)).deny).toMatch(/android \| ios/)
  expect((await bash(`PLATFORM=windows CAPABILITIES=tests/capabilities/win.json npx playwright test ${cfg}`)).deny).toMatch(/not implemented yet/)
  expect((await bash('PLATFORM=ios CAPABILITIES=tests/capabilities/iphone.json npx playwright test tests/platform/a.spec.ts')).deny).toMatch(/playwright\.platform\.config\.ts/)
  h.write(`${ROOT}/package.json`, JSON.stringify({ scripts: { 'test:platform': 'playwright test -c playwright.platform.config.ts', test: 'playwright test -c playwright.platform.config.ts' } }))
  for (const run of ['npm run test:platform', 'pnpm test:platform', 'yarn test:platform', 'pnpm run test:platform', 'npm test', 'npm t', 'yarn test', 'npm --silent test', 'npm -s run test:platform', 'yarn -s test:platform']) {
    expect((await bash(`PLATFORM=ios CAPABILITIES=tests/capabilities/iphone.json ${run}`)).deny).toBeUndefined()
    expect((await bash(`PLATFORM=ios CAPABILITIES=/tmp/x.json ${run}`)).deny).toMatch(/tests\/capabilities\//)
  }
  expect((await bash('pnpm install')).deny).toBeUndefined()
})

test('a line too long to split that names wdio is refused', async ($, on) => {
  const h = engine(on)
  const { bash } = await setup($, h)
  expect((await bash(`echo ${'w '.repeat(17000)}; npx wdio session open ios`)).deny).toMatch(/too long to judge/)
})
