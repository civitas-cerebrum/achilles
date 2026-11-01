import { expect, test } from 'claude-code/testing'

import { START, ended, engine, spawnExpert, startRun } from './harness'

const PANE = {
  plugin: 'achilles',
  component: 'Pane',
  requestId: 'achilles',
  props: { title: 'Achilles', isFocused: false, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
} as const

test('/achilles with no task opens the pane; with a task it delegates', async ($, on) => {
  const opened: string[] = []
  on('ui.open', (_, e) => (opened.push(e.id), { value: { isPlaced: true } }))
  const h = engine(on)
  await $.session.start(START)
  expect((await $.command.run({ command: 'achilles', args: '' } as never)).text).toContain('pane opened')
  expect(opened).toEqual(['achilles'])
  expect((await $.command.run({ command: 'achilles', args: 'verify login' } as never)).text).toMatch(/^RUNNING qa-/)
  expect(h.spawns.length).toBe(1)
})

test('the pane draws the runs, their experts and the last hand-back, on every surface', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /No QA run in flight/ }))?.text).toContain('No QA run')
    await ui.unmount()
  }
  const orchestrator = await startRun($, h, 'verify the checkout')
  const author = await spawnExpert($, h, 'author', orchestrator)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /verify the checkout/ }))?.text).toContain('verify the checkout')
    expect((await ui.find({ type: 'Text', text: new RegExp(`author ${author}`) }))?.text).toContain('.achilles/runs/x/briefs/b.md')
    await ui.unmount()
  }
  await $.turn.complete(ended(author, 'DONE\nwrote'))
  await $.turn.complete(ended(orchestrator, 'DONE\nCheckout verified.'))
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /Last hand-back/ }))?.text).toContain('Last hand-back')
  expect((await ui.find({ type: 'Text', text: /Checkout verified/ }))?.text).toBe('Checkout verified.')
  await ui.unmount()
})
