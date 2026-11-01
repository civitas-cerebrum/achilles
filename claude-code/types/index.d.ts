/** One expert loop the orchestrator has running, by its agent id and role (inspector, author, reviewer, doc-writer). */
export type AchillesExpert = {
  agentId: string
  role: string
  /** The brief file the dispatch prompt named, when it named one. */
  brief?: string
  /** The report path the dispatch prompt named, when it named one. */
  report?: string
  /** The return schema (schemas/subagent-returns/<name>.schema.json) the brief named or the role defaults to. */
  schema?: string
  /** The workflow the brief loads, as far as the brief says: diagnosis, selector, review, compose, perf, other. */
  kind?: string
  /** playwright-cli session slugs this expert ran with; closed at its end. */
  slugs?: string[]
  /** The skills the expert loaded with its Skill tool. */
  skills?: string[]
  /** True once the expert opened failure evidence (a trace, screenshot, error context, video or results file). */
  evidence?: boolean
  /** When the expert was dispatched (epoch ms). */
  since?: number
}

/** One stage of a run's workflow: a pipeline ledger's phase, or an entry of the plan in the run's resume.json. */
export type AchillesStage = { name: string; status: string }

/** An expert that handed back, with the status word that opened its answer. */
export type AchillesFinished = { role: string; slug?: string; status: string; at: number }

/** The selector-development pipeline in flight: the eight-step journal the hooks observe. */
export type AchillesSelectorScope = {
  scope: string
  files: string[]
  steps: { name: string; status: 'pass' | 'fail' }[]
}

/** One delegated QA task: the orchestrator loop running it (once known) and the experts it has running now. */
export type AchillesRun = {
  id: string
  task: string
  dir: string
  agentId?: string
  experts: AchillesExpert[]
  /** Experts dispatched so far, by role. */
  dispatched?: Record<string, number>
  /** The judge loop: the last reviewer verdict and how many consecutive improvements-needed verdicts. */
  judge?: { last: 'satisfied' | 'not-satisfied'; consecutive: number }
  /** Playwright run archives the reporting hook wrote during this run. */
  archived?: number
  selector?: AchillesSelectorScope
  /** When the run was delegated (epoch ms). */
  startedAt?: number
  /** The pipeline ledger the run's stages are read from, once known (project-relative). */
  ledger?: string
  /** The run's stages as of the last progress refresh. */
  stages?: AchillesStage[]
  /** The `step` the orchestrator last wrote to its resume.json. */
  step?: string
  /** The experts that handed back, oldest first, the last few kept. */
  finished?: AchillesFinished[]
}

declare module 'claude-code' {
  interface PluginState {
    achilles: {
      runs: AchillesRun[]
      /** The hash of each pipeline ledger's content as of its last write made through the tools, by project-relative path. */
      ledgers: Record<string, string>
      /** The hash of each sign-off receipt as the adapter recorded it from the reviewers' reports, by absolute path. */
      receipts: Record<string, string>
      /** The last hand-back delivered to the main session, for the pane. */
      handback: { run: string; task: string; text: string }
    }
  }
}
