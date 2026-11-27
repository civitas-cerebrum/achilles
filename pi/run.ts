// The host process runner of the pi guards (the `process.run` noun of the Claude Code `$` the shared judge
// and lint child use). Node imports only, so it can be loaded on its own.
import { spawn } from 'node:child_process'
import { constants } from 'node:os'

export type RunInit = { cwd?: string; stdin?: string; timeoutMs?: number; env?: Record<string, string> }
export type RunResult = { stdout: string; stderr: string; exitCode: number }

/** After the child exits, how long its output pipes may stay open (a grandchild holding them) before the result is taken as it is. */
export const DRAIN_MS = 250

/** A child killed by a signal reads as 128 + its number, as a shell reports it: never as a code the program itself uses (1 is "findings" to the lint). */
const exitOf = (code: number | null, signal: NodeJS.Signals | null) => code ?? 128 + ((signal && constants.signals[signal]) || 0)

/**
 * Runs `argv` and resolves with its output and exit code. The wait is a bound: past `timeoutMs` the child is
 * killed outright and the call fails, even when the child ignores SIGTERM or a grandchild still holds its pipes.
 * A child that exits first is reported with its own exit code, also when it left a large stdin unread or a
 * grandchild keeps the pipes open.
 */
export function runProcess(argv: string[], o: RunInit = {}, root = process.cwd()): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const p = spawn(argv[0]!, argv.slice(1), { cwd: o.cwd ?? root, env: { ...process.env, ...o.env } })
    let stdout = ''
    let stderr = ''
    let settled = false
    let drain: ReturnType<typeof setTimeout> | undefined
    const finish = (f: () => void) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      if (drain) clearTimeout(drain)
      f()
    }
    const timer = o.timeoutMs
      ? setTimeout(() => {
          p.kill('SIGKILL')
          p.stdout.destroy()
          p.stderr.destroy()
          finish(() => reject(new Error(`timed out after ${o.timeoutMs} ms`)))
        }, o.timeoutMs)
      : undefined
    p.stdout.on('data', d => (stdout += d))
    p.stderr.on('data', d => (stderr += d))
    p.on('error', err => finish(() => reject(err)))
    p.on('close', (code, signal) => finish(() => resolve({ stdout, stderr, exitCode: exitOf(code, signal) })))
    // The child is gone: what it did not read of stdin never will be, and output still in flight gets a moment.
    p.on('exit', (code, signal) => {
      p.stdin.destroy()
      drain = setTimeout(() => {
        p.stdout.destroy()
        p.stderr.destroy()
        finish(() => resolve({ stdout, stderr, exitCode: exitOf(code, signal) }))
      }, DRAIN_MS)
    })
    // A child that exits before reading all of a large stdin closes the pipe: EPIPE is not this process's death.
    p.stdin.on('error', () => undefined)
    p.stdin.end(o.stdin ?? '')
  })
}
