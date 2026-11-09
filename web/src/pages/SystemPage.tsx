// System health — a checklist of OK / Warning / Problem rows, each with a plain
// fix hint, then the recent warnings and errors. Read-only; no secrets are
// shown. Backups are managed on Settings > Backups; the Backups row here shows
// the last backup and links there.

import React from 'react'
import { ApiError, getAdminHealth, getSystemChecks } from '../lib/api'
import type { AdminHealth, CheckStatus, SystemCheck, SystemChecks } from '../lib/types'
import { isAccessDenied } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState } from '../components/primitives'
import { Alert, PageHeader, Section } from '../components/patterns'
import { formatRelativeTime } from '../lib/format'
import { browserSkewSeconds, groupChecks, overallBanner, STATUS_LABEL, STATUS_TONE } from '../lib/systemChecks'
import './pages.css'
import './SystemPage.css'

const AUTO_MS = 30_000

interface Loaded {
  checks: SystemChecks
  health: AdminHealth | null
  at: Date
}

function scrollToId(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

export function SystemPage({ onOpen }: { onOpen?: (hash: string) => void }) {
  const [data, setData] = React.useState<Loaded | null>(null)
  const [error, setError] = React.useState<{ status: number; message: string } | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [auto, setAuto] = React.useState(false)
  const inflight = React.useRef(false)

  const load = React.useCallback(async () => {
    if (inflight.current) return
    inflight.current = true
    setLoading(true)
    try {
      const [checks, health] = await Promise.all([
        getSystemChecks(),
        // The error list is secondary: a failure here must not hide the checklist.
        getAdminHealth().catch(() => null),
      ])
      setData({ checks, health, at: new Date() })
      setError(null)
    } catch (e) {
      setError(
        e instanceof ApiError
          ? { status: e.status, message: e.message }
          : { status: 0, message: e instanceof Error ? e.message : 'Could not load system health.' },
      )
    } finally {
      inflight.current = false
      setLoading(false)
    }
  }, [])

  React.useEffect(() => {
    void load()
  }, [load])

  React.useEffect(() => {
    if (!auto) return
    const t = window.setInterval(() => void load(), AUTO_MS)
    return () => window.clearInterval(t)
  }, [auto, load])

  if (isAccessDenied(error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const refreshing = loading && !!data

  return (
    <div className="wb-page">
      <PageHeader
        title="System health"
        subtitle="Is the server healthy? Each row says what is checked and how to fix it."
        actions={
          <div className="wb-sys-tools">
            {data && <span className="wb-sys-updated">Updated {data.at.toLocaleTimeString()}</span>}
            <label className="wb-sys-auto">
              <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} />
              Auto-refresh (30 s)
            </label>
            <Button variant="secondary" size="sm" onClick={() => void load()} loading={refreshing} aria-label="Refresh system health">
              {refreshing ? 'Refreshing' : 'Refresh'}
            </Button>
          </div>
        }
      />

      {loading && !data && !error ? (
        <SystemSkeleton />
      ) : error && !data ? (
        <ErrorState title="Couldn’t load system health" description={error.message} onRetry={() => void load()} />
      ) : data ? (
        <>
          {error && (
            <Alert tone="warning" title="Couldn’t refresh">
              {error.message} Showing the information from {data.at.toLocaleTimeString()}.
            </Alert>
          )}
          <Checklist checks={data.checks} onOpen={onOpen} />
          <div id="recent-errors">
            <RecentErrors health={data.health} />
          </div>
        </>
      ) : null}
    </div>
  )
}

function SystemSkeleton() {
  return (
    <div className="wb-sys-skeleton" aria-busy="true" aria-label="Loading system health">
      <div className="wb-skeleton" style={{ height: 64 }} />
      {[0, 1, 2].map((i) => (
        <div key={i} className="wb-sys-skel-card">
          <div className="wb-skeleton" style={{ height: 14, width: 120 }} />
          <div className="wb-skeleton wb-skeleton-row" />
          <div className="wb-skeleton wb-skeleton-row" />
        </div>
      ))}
    </div>
  )
}

function Checklist({ checks, onOpen }: { checks: SystemChecks; onOpen?: (hash: string) => void }) {
  const list: SystemCheck[] = [...checks.checks]
  // The browser knows its own clock; the server cannot. Flag a big gap.
  const skew = browserSkewSeconds(checks.generated_at, Date.now())
  const counts = { ...checks.counts }
  if (Math.abs(skew) > 120) {
    list.push({
      id: 'browser_clock',
      group: 'Server',
      title: 'Clock (this computer)',
      status: 'warn',
      summary: `This computer’s clock is ${Math.abs(skew)} seconds ${skew > 0 ? 'ahead of' : 'behind'} the server.`,
      hint: 'Check the time on the computer you are using. If the server is wrong instead, turn on automatic time on its host.',
    })
    counts.warn = (counts.warn ?? 0) + 1
  }
  const banner = overallBanner(counts)
  const groups = groupChecks(list)
  return (
    <>
      <Alert tone={banner.tone} title={banner.title}>
        {banner.text}
      </Alert>
      <div className="wb-sys-counts" aria-label="Summary of checks">
        {(['fail', 'warn', 'ok', 'info'] as CheckStatus[]).map((s) => (
          <Badge key={s} tone={STATUS_TONE[s]} dot>
            {counts[s] ?? 0} {STATUS_LABEL[s].toLowerCase()}
          </Badge>
        ))}
      </div>
      {groups.map((g) => (
        <Section key={g.group} title={g.group}>
          <Card padded={false}>
            <ul className="wb-sys-checks">
              {g.checks.map((c) => (
                <CheckRow key={c.id} c={c} onOpen={onOpen} />
              ))}
            </ul>
          </Card>
        </Section>
      ))}
    </>
  )
}

function CheckRow({ c, onOpen }: { c: SystemCheck; onOpen?: (hash: string) => void }) {
  const needsFix = (c.status === 'fail' || c.status === 'warn') && c.hint
  return (
    <li className={`wb-sys-check wb-sys-check-${c.status}`}>
      <div className="wb-sys-check-status">
        <Badge tone={STATUS_TONE[c.status]} dot>
          {STATUS_LABEL[c.status]}
        </Badge>
      </div>
      <div className="wb-sys-check-body">
        <div className="wb-sys-check-title">{c.title}</div>
        <div className="wb-sys-check-summary">{c.summary}</div>
        {needsFix && (
          <div className="wb-sys-check-hint">
            <strong>How to fix:</strong> {c.hint}
          </div>
        )}
        {!needsFix && (c.status === 'info' || c.status === 'ok') && c.hint && (
          <div className="wb-sys-check-hint wb-sys-check-hint-soft">{c.hint}</div>
        )}
        {c.link && (
          <div className="wb-sys-check-link">
            {c.link.startsWith('#/') ? (
              <a
                href={c.link}
                onClick={(e) => {
                  if (!onOpen || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
                  e.preventDefault()
                  onOpen(c.link!)
                }}
              >
                {c.link_label || 'Details'}
              </a>
            ) : c.link.startsWith('#') ? (
              <button type="button" className="wb-sys-linkbtn" onClick={() => scrollToId(c.link!.slice(1))}>
                {c.link_label || 'Details'}
              </button>
            ) : (
              <a href={c.link} target="_blank" rel="noreferrer">
                {c.link_label || 'Learn more'}
              </a>
            )}
          </div>
        )}
      </div>
    </li>
  )
}

function RecentErrors({ health }: { health: AdminHealth | null }) {
  return (
    <Section title="Recent warnings and errors" description="Since the server last started. Only short messages are kept; no personal data.">
      {!health ? (
        <EmptyState title="Couldn’t load the list" description="The checklist above is still accurate. Press Refresh to try again." />
      ) : health.recent_errors.length === 0 ? (
        <EmptyState title="Nothing to report" description="No warnings or errors since the server started." />
      ) : (
        <Card padded={false}>
          <ul className="wb-sys-log">
            {health.recent_errors.map((e, i) => (
              <li key={`${e.time}-${i}`} className="wb-sys-log-row">
                <Badge tone={e.level === 'ERROR' ? 'red' : 'orange'}>{e.level.toLowerCase()}</Badge>
                <span className="wb-sys-log-msg">{e.message}</span>
                <span className="wb-sys-log-time" title={new Date(e.time).toLocaleString()}>
                  {formatRelativeTime(e.time)}
                </span>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </Section>
  )
}
