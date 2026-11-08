// Pure helpers for the System health checklist.

import type { CheckStatus, SystemCheck } from './types'

export const STATUS_LABEL: Record<CheckStatus, string> = {
  ok: 'OK',
  warn: 'Warning',
  fail: 'Problem',
  info: 'Info',
}

export const STATUS_TONE: Record<CheckStatus, 'green' | 'orange' | 'red' | 'neutral'> = {
  ok: 'green',
  warn: 'orange',
  fail: 'red',
  info: 'neutral',
}

/** One sentence for the top banner. Never says "all good" while a row is red or orange. */
export function overallBanner(counts: Partial<Record<CheckStatus, number>> | undefined): {
  tone: 'success' | 'warning' | 'danger'
  title: string
  text: string
} {
  const fail = counts?.fail ?? 0
  const warn = counts?.warn ?? 0
  if (fail > 0) {
    return {
      tone: 'danger',
      title: 'Needs attention',
      text: `${fail} check${fail === 1 ? '' : 's'} failed${warn ? ` and ${warn} need a look` : ''}. Start with the red rows.`,
    }
  }
  if (warn > 0) {
    return {
      tone: 'warning',
      title: 'Mostly fine',
      text: `${warn} check${warn === 1 ? '' : 's'} could be better. Nothing is broken.`,
    }
  }
  return { tone: 'success', title: 'Everything looks good', text: 'All checks passed.' }
}

/** Problems first, then group order of first appearance. */
export function groupChecks(checks: SystemCheck[]): { group: string; checks: SystemCheck[] }[] {
  const groups: { group: string; checks: SystemCheck[] }[] = []
  for (const c of checks) {
    let g = groups.find((x) => x.group === c.group)
    if (!g) groups.push((g = { group: c.group, checks: [] }))
    g.checks.push(c)
  }
  return groups
}

/** Difference between the browser clock and the server's generated_at, in seconds. */
export function browserSkewSeconds(generatedAt: string, browserNow: number): number {
  const t = Date.parse(generatedAt)
  if (Number.isNaN(t)) return 0
  return Math.round((browserNow - t) / 1000)
}
