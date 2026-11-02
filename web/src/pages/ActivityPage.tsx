// Activity feed — a read-only, newest-first stream of arrivals, departures,
// SOS/help alerts, check-ins and crash reports across every family.

import React from 'react'
import { ApiError, listActivity, listFamilies } from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, Card, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { formatRelativeTime } from '../lib/format'
import type { ActivityEvent, ActivityKind } from '../lib/types'
import './pages.css'
import './ActivityPage.css'

const KINDS: { key: ActivityKind; label: string }[] = [
  { key: 'arrival', label: 'Arrivals' },
  { key: 'departure', label: 'Departures' },
  { key: 'sos', label: 'SOS' },
  { key: 'help', label: 'Help' },
  { key: 'check_in', label: 'Check-ins' },
  { key: 'crash', label: 'Crashes' },
  { key: 'bubble_created', label: 'Bubbles' },
]

type Tone = 'green' | 'neutral' | 'orange' | 'pink' | 'purple'

function describe(e: ActivityEvent): { tone: Tone; label: string; text: string } {
  const place = e.detail
  switch (e.kind) {
    case 'arrival':
      return { tone: 'green', label: 'Arrived', text: place ? `arrived at ${place}` : 'arrived at a place' }
    case 'departure':
      return { tone: 'neutral', label: 'Left', text: place ? `left ${place}` : 'left a place' }
    case 'sos':
      return { tone: 'pink', label: 'SOS', text: `sent an SOS${e.detail ? ` — ${e.detail}` : ''}` }
    case 'help':
      return { tone: 'orange', label: 'Help', text: `asked for help${e.detail ? ` — ${e.detail}` : ''}` }
    case 'check_in':
      return { tone: 'purple', label: 'Check-in', text: `checked in${e.detail ? ` — ${e.detail}` : ''}` }
    case 'crash':
      return { tone: 'orange', label: 'Crash', text: `possible crash — ${e.detail}` }
    case 'bubble_created':
      return { tone: 'purple', label: 'Bubble', text: `created a Bubble around ${e.detail || 'someone'}` }
    case 'bubble_entered':
      return { tone: 'green', label: 'Bubble', text: `— ${e.detail || 'someone'} is back inside their Bubble` }
    case 'bubble_left':
      return { tone: 'orange', label: 'Bubble', text: `— ${e.detail || 'someone'} left their Bubble` }
  }
}

function mapLink(e: ActivityEvent): string | null {
  if (e.lat === undefined || e.lon === undefined || e.lat === null || e.lon === null) return null
  return `https://www.openstreetmap.org/?mlat=${e.lat}&mlon=${e.lon}#map=17/${e.lat}/${e.lon}`
}

export function ActivityPage() {
  const familiesQ = useAsync(listFamilies, [])
  const [kinds, setKinds] = React.useState<Set<ActivityKind>>(new Set())
  const [family, setFamily] = React.useState('')
  const [events, setEvents] = React.useState<ActivityEvent[]>([])
  const [next, setNext] = React.useState<string | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [loadingMore, setLoadingMore] = React.useState(false)
  const [error, setError] = React.useState<{ status: number; message: string } | null>(null)

  const typeParam = React.useMemo(() => {
    const k = [...kinds]
    // The "Bubbles" chip covers every bubble event.
    if (kinds.has('bubble_created')) k.push('bubble_entered', 'bubble_left')
    return k.join(',')
  }, [kinds])

  const load = React.useCallback(
    async (before?: string) => {
      before ? setLoadingMore(true) : setLoading(true)
      setError(null)
      try {
        const page = await listActivity({ before, type: typeParam, family_id: family, limit: 50 })
        setEvents((cur) => (before ? [...cur, ...page.events] : page.events))
        setNext(page.next_before)
      } catch (e) {
        setError({
          status: e instanceof ApiError ? e.status : 0,
          message: e instanceof Error ? e.message : 'Request failed',
        })
      } finally {
        setLoading(false)
        setLoadingMore(false)
      }
    },
    [typeParam, family],
  )
  React.useEffect(() => {
    void load()
  }, [load])

  if (isAccessDenied(error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const toggle = (k: ActivityKind) =>
    setKinds((cur) => {
      const n = new Set(cur)
      if (n.has(k)) n.delete(k)
      else n.add(k)
      return n
    })

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Activity</h1>
          <p className="wb-page-subtitle">
            Arrivals, departures, alerts, check-ins and crash reports from every family.
          </p>
        </div>
        <Button variant="secondary" size="sm" onClick={() => void load()}>
          Refresh
        </Button>
      </div>

      <div className="wb-activity-filters">
        <div className="wb-activity-chips" role="group" aria-label="Event types">
          {KINDS.map((k) => (
            <button
              key={k.key}
              type="button"
              className={`wb-activity-chip${kinds.has(k.key) ? ' is-on' : ''}`}
              aria-pressed={kinds.has(k.key)}
              onClick={() => toggle(k.key)}
            >
              {k.label}
            </button>
          ))}
        </div>
        <label className="wb-field" htmlFor="activity-family">
          <span className="wb-label">Family</span>
          <select
            id="activity-family"
            className="wb-select"
            value={family}
            onChange={(e) => setFamily(e.target.value)}
          >
            <option value="">All families</option>
            {(familiesQ.data ?? []).map((f) => (
              <option key={f.id} value={f.id}>
                {f.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      {loading && events.length === 0 ? (
        <div className="wb-page-loading">
          <Spinner /> Loading activity…
        </div>
      ) : error ? (
        <ErrorState title="Couldn’t load activity" description={error.message} onRetry={() => void load()} />
      ) : events.length === 0 ? (
        <EmptyState title="No activity" description="Nothing has happened that matches these filters yet." />
      ) : (
        <Card padded={false}>
          <ul className="wb-activity-list">
            {events.map((e, i) => {
              const d = describe(e)
              const link = mapLink(e)
              return (
                <li key={`${e.kind}-${e.user_id}-${e.at}-${i}`} className="wb-activity-row">
                  <Badge tone={d.tone}>{d.label}</Badge>
                  <div className="wb-activity-main">
                    <span className="wb-activity-text">
                      <strong>{e.user_name}</strong> {d.text}
                    </span>
                    <span className="wb-activity-sub">
                      {e.family_name || 'No family'}
                      {e.status && e.kind !== 'arrival' && e.kind !== 'departure' ? ` · ${e.status}` : ''}
                      {link && (
                        <>
                          {' · '}
                          <a href={link} target="_blank" rel="noopener noreferrer">
                            View on map
                          </a>
                        </>
                      )}
                    </span>
                  </div>
                  <time className="wb-activity-time" dateTime={e.at} title={new Date(e.at).toLocaleString()}>
                    {formatRelativeTime(e.at)}
                  </time>
                </li>
              )
            })}
          </ul>
        </Card>
      )}
      {next && (
        <div className="wb-activity-more">
          <Button variant="secondary" loading={loadingMore} onClick={() => void load(next)}>
            Load older activity
          </Button>
        </div>
      )}
    </div>
  )
}
