import type { EngineInterface, On } from 'claude-code'

import type { AchillesStage } from '../types'
import { ENDED, currentStage, isDisabled, readRuns, stageLine } from './context'

// The Achilles pane: `/achilles` with no task opens it beside the chat. It draws the runs in
// flight, their stages (done, current, to go), the experts at work and the last few that handed
// back, the judge loop and selector scope, and the last hand-back, all from $.state, so a state
// write redraws it.

const MARK: Record<string, string> = { completed: '✓', skipped: '–', blocked: '✗', failed: '✗' }
const stageMark = (s: AchillesStage, cur: AchillesStage | undefined) => (s === cur ? '▸' : ENDED.has(s.status) ? (MARK[s.status] ?? '✓') : '·')
const clock = (ms: number | undefined) => (ms === undefined ? '' : ` · since ${new Date(ms).toTimeString().slice(0, 5)}`)

export const PANE = 'achilles'

export async function rememberHandback($: EngineInterface, run: string, task: string, text: string) {
  await $.state.set({ plugin: 'achilles', key: 'handback' }, { run, task, text: text.slice(0, 2000) })
}

export function registerPane(on: On) {
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const runs = await readRuns($)
    const { value: last } = await $.state.get({ plugin: 'achilles', key: 'handback' })
    const width = Math.max(20, (e.props.bodyColumns ?? 60) - 2)
    const cut = (s: string) => (s.length > width ? `${s.slice(0, width - 1)}…` : s)
    return (
      <Box flexDirection="column">
        {isDisabled() && <Text color="yellow">Achilles is switched off (ACHILLES_DISABLE=1).</Text>}
        {runs.length === 0 && <Text dimColor>No QA run in flight. Delegate one with /achilles &lt;task&gt;.</Text>}
        {runs.map(run => (
          <Box key={run.id} flexDirection="column" marginBottom={1}>
            <Text bold>{cut(`${run.id}  ${run.task}`)}</Text>
            <Text dimColor>{cut(`orchestrator ${run.agentId ?? 'starting'} · state ${run.dir}/`)}</Text>
            {stageLine(run) && <Text>{cut(`  ${stageLine(run)}`)}</Text>}
            {(run.stages ?? []).map((s, i) => (
              <Text key={`s${i}`} dimColor={ENDED.has(s.status)} bold={s === currentStage(run.stages)}>
                {cut(`  ${stageMark(s, currentStage(run.stages))} ${s.name}${ENDED.has(s.status) && s.status !== 'completed' ? ` (${s.status})` : ''}`)}
              </Text>
            ))}
            {run.experts.length === 0 && <Text dimColor>  no expert running</Text>}
            {run.experts.map(x => (
              <Text key={x.agentId}>{cut(`  ${x.role} ${x.agentId}${x.brief ? ` · ${x.brief}` : ''}${clock(x.since)}`)}</Text>
            ))}
            {(run.finished ?? []).slice(-3).map((f, i) => (
              <Text key={`f${i}`} dimColor>
                {cut(`  handed back: ${f.role}${f.slug ? ` ${f.slug}` : ''} ${f.status}`)}
              </Text>
            ))}
            {run.judge && run.judge.consecutive > 0 && <Text color="yellow">{`  judge loop open ${run.judge.consecutive}/3`}</Text>}
            {run.selector && <Text>{cut(`  selector ${run.selector.scope}: ${run.selector.steps.map(s => `${s.name}${s.status === 'fail' ? '✗' : ''}`).join(' → ')}`)}</Text>}
          </Box>
        ))}
        {last && (
          <Box flexDirection="column">
            <Text bold>{cut(`Last hand-back · ${last.run}`)}</Text>
            {last.text.split('\n').slice(0, 12).map((line, i) => (
              <Text key={`h${i}`}>{cut(line)}</Text>
            ))}
          </Box>
        )}
      </Box>
    )
  })
}
