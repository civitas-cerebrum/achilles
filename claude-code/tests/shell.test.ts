import { expect, test } from 'claude-code/testing'

import { commands, gitCall, isReader, nestedCommand, words } from '../hooks/shell'

const args = (line: string) => commands(line).commands.map(c => c.args)

test('words: quoting, escapes, substitutions and comments split as the shell does', () => {
  expect(words(`echo 'a b' "c d" e\\ f`).words.map(w => w.text)).toEqual(['echo', 'a b', 'c d', 'e f'])
  expect(words('x=$(echo "a; b") y').words.map(w => w.text)).toEqual(['x=$(echo "a; b")', 'y'])
  expect(words('ls `cat f; rm x`').words.map(w => w.text)).toEqual(['ls', '`cat f; rm x`'])
  expect(words('ls # not; a | command').words.map(w => w.text)).toEqual(['ls'])
  expect(words('printf "%s\\n" "x=playwright-cli"').words.map(w => w.text)).toEqual(['printf', '%s\\n', 'x=playwright-cli'])
  expect(words('a'.repeat(40000)).overflow).toBe(true)
})

test('commands: separators, redirections, fd numbers and heredocs', () => {
  expect(args('cd app && npx playwright-cli open http://x; echo done | tee log')).toEqual([['cd', 'app'], ['playwright-cli', 'open', 'http://x'], ['echo', 'done'], ['tee', 'log']])
  const [redir] = commands('echo x 2>&1 >/tmp/log').commands
  expect(redir?.writes).toEqual(['/tmp/log'])
  const [clobber] = commands(': >| tests/e2e/docs/onboarding-status.json').commands
  expect(clobber?.writes).toEqual(['tests/e2e/docs/onboarding-status.json'])
  const [hd] = commands('cat > notes.md <<EOF\nnpx playwright-cli open http://app\nEOF').commands
  expect(hd?.writes).toEqual(['notes.md'])
  expect(hd?.heredocs).toEqual(['npx playwright-cli open http://app\n'])
  expect(hd?.args).toEqual(['cat'])
  const [here] = commands('git commit -F - <<<"test(j-x): fix"').commands
  expect(here?.heredocs).toEqual(['test(j-x): fix'])
})

test('commands: wrappers, assignments, keywords and package specs are peeled to the program', () => {
  expect(args('FOO=1 npx playwright-cli open http://x')[0]).toEqual(['playwright-cli', 'open', 'http://x'])
  expect(commands('FOO=1 npx playwright-cli open').commands[0]?.assign).toEqual(['FOO=1'])
  expect(args('npx @playwright/cli@1.2.0 open http://x')[0]).toEqual(['@playwright/cli', 'open', 'http://x'])
  expect(args('npm exec -- playwright-cli open http://x')[0]).toEqual(['playwright-cli', 'open', 'http://x'])
  expect(args('pnpm exec playwright-cli -s=composer-j-x-1-c1 open')[0]).toEqual(['playwright-cli', '-s=composer-j-x-1-c1', 'open'])
  expect(args('if npx playwright-cli open http://x; then echo ok; fi')).toEqual([['playwright-cli', 'open', 'http://x'], ['echo', 'ok']])
  expect(args('./node_modules/.bin/playwright-cli open http://x')[0]).toEqual(['playwright-cli', 'open', 'http://x'])
  expect(args('command git commit --no-verify -m x')[0]).toEqual(['git', 'commit', '--no-verify', '-m', 'x'])
  expect(args('command -v playwright-cli')[0]).toEqual(['command', '-v', 'playwright-cli'])
  const [envC] = commands('env -C /tmp playwright-cli open http://x').commands
  expect(envC?.chdir).toBe('/tmp')
  expect(envC?.args).toEqual(['playwright-cli', 'open', 'http://x'])
  expect(commands('setsid playwright-cli open https://x').commands[0]?.args[0]).toBe('setsid')
  expect(commands('npx --unknown-opt playwright-cli open').commands[0]?.wrapBad).toBe(true)
  expect(commands('npx --no-install playwright-cli --version').commands[0]?.wrapBad).toBe(false)
  expect(args('timeout 30 k6 run x.js')[0]).toEqual(['k6', 'run', 'x.js'])
})

test('commands: spans point back at the source so a rewrite can insert after the command word', () => {
  const line = 'cd app && npx playwright-cli open http://x'
  const pw = commands(line).commands[1]!
  expect(line.slice(pw.spans[0]!.start, pw.spans[0]!.end)).toBe('playwright-cli')
})

test('readers, nested shells and git calls', () => {
  expect(isReader(['grep', '-rn', 'x', 'hooks/'])).toBe(true)
  expect(isReader(['git', 'log', '--grep', 'x'])).toBe(true)
  expect(isReader(['git', 'checkout', 'x'])).toBe(false)
  expect(isReader(['npm', 'view', '@playwright/cli'])).toBe(true)
  expect(isReader(['rm', 'x'])).toBe(false)
  expect(nestedCommand(['bash', '-lc', 'git commit -m x'])).toBe('git commit -m x')
  expect(nestedCommand(['sh', '-c', 'echo hi'])).toBe('echo hi')
  expect(nestedCommand(['eval', 'rm', 'x'])).toBe('rm x')
  expect(nestedCommand(['bash', 'script.sh'])).toBeUndefined()
  expect(gitCall(['git', '-c', 'commit.gpgsign=false', 'commit', '-m', 'x'])).toEqual({ sub: 'commit', rest: ['-m', 'x'], configs: ['commit.gpgsign=false'], dirs: [] })
  expect(gitCall(['git', '-C', '../proj', 'push', '--force'])).toEqual({ sub: 'push', rest: ['--force'], configs: [], dirs: ['../proj'] })
  expect(gitCall(['ls'])).toBeUndefined()
})
