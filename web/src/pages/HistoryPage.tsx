// History page — per-member day trail on the map plus a visit timeline.
// Filters (family / member / date) sit with the map they control. Live
// positions stay on the Dashboard so a trail is never confused with "now".
//
// Permissions mirror the mobile apps: platform admins can pick any family and
// member; regular users see their own circle only, through the same
// /family/members/{id}/history endpoint the app's day-detail screen uses.

import React from 'react'
import { CircleMarker, MapContainer, Polyline, useMap } from 'react-leaflet'
import {
  getFamilyMemberHistory,
  getMemberHistory,
  listAllMembers,
  listFamilies,
  listMyFamilyMembers,
  getMyFamily,
} from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { useMe } from '../lib/me'
import { Badge, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { BaseMapLayer } from '../map/BaseMapLayer'
import type { AdminMember, Family, HistoryVisit, Member, MemberHistory, MyFamily } from '../lib/types'
import './pages.css'
import './HistoryPage.css'

/**
 * History trail + place-visit markers. Deliberately NOT the brand lime: the
 * accent disappears over the OSM basemap's vegetation greens (#ADD19E/#CDEBB0),
 * which made the trail invisible over parks (Rio de Janeiro regression). Deep
 * violet reads on every basemap surface — greens, land #F2EFE9, water
 * #AAD3DF, white roads — rendered over a white casing for busy urban tiles.
 * Matches AppColors.historyTrail (#7C3AED) in the Flutter app so the day
 * trail looks identical in both UIs.
 */
const TRAIL_COLOR = '#7c3aed'

function todayISO(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function parseHistoryHash(): { member: string; date: string } {
  const hash = typeof window === 'undefined' ? '' : window.location.hash
  const q = new URLSearchParams(hash.includes('?') ? hash.slice(hash.indexOf('?') + 1) : '')
  return { member: q.get('member') ?? '', date: q.get('date') ?? todayISO() }
}

function writeHistoryHash(member: string, date: string): void {
  const params = new URLSearchParams()
  if (member) params.set('member', member)
  if (date) params.set('date', date)
  const qs = params.toString()
  const next = qs ? `#/history?${qs}` : '#/history'
  if (window.location.hash !== next) {
    window.location.hash = next
  }
}

function dayBounds(dateISO: string): { from: string; to: string } {
  const from = new Date(`${dateISO}T00:00:00`)
  const to = new Date(from)
  to.setDate(to.getDate() + 1)
  return { from: from.toISOString(), to: to.toISOString() }
}

function formatTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

function formatStay(fromISO: string, toISO: string): string {
  const ms = new Date(toISO).getTime() - new Date(fromISO).getTime()
  if (!Number.isFinite(ms) || ms < 60_000) return ''
  const mins = Math.round(ms / 60_000)
  if (mins < 60) return `${mins} min`
  const h = Math.floor(mins / 60)
  const m = mins % 60
  return m === 0 ? `${h}h` : `${h}h ${m}m`
}

export function HistoryPage() {
  const { isPlatformAdmin } = useMe()
  const families = useAsync(
    () => (isPlatformAdmin ? listFamilies() : getMyFamily().then(familyToList)),
    [isPlatformAdmin],
  )
  // AdminMember (server-wide rows) for admins; plain Member rows from the
  // caller's own family otherwise — the member picker renders either way.
  const members = useAsync<Member[] | AdminMember[]>(
    () => (isPlatformAdmin ? listAllMembers() : listMyFamilyMembers()),
    [isPlatformAdmin],
  )
  const initial = React.useMemo(parseHistoryHash, [])
  const [familyId, setFamilyId] = React.useState('')
  const [memberId, setMemberId] = React.useState(initial.member)
  const [date, setDate] = React.useState(initial.date)
  const [history, setHistory] = React.useState<MemberHistory | null>(null)
  const [loading, setLoading] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)
  const [reload, setReload] = React.useState(0)

  React.useEffect(() => {
    const onHash = () => {
      const next = parseHistoryHash()
      setMemberId(next.member)
      setDate(next.date || todayISO())
    }
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const memberList = members.data ?? []
  const familyList = families.data ?? []

  React.useEffect(() => {
    // Only admins can cross families; regular users are scoped to their own.
    if (!isPlatformAdmin || !memberId || memberList.length === 0) return
    const selected = memberList.find((m) => m.id === memberId) as AdminMember | undefined
    if (selected && selected.family_id && selected.family_id !== familyId) {
      setFamilyId(selected.family_id)
    }
  }, [isPlatformAdmin, memberId, memberList, familyId])

  const visibleMembers = React.useMemo(() => {
    if (!isPlatformAdmin || !familyId) return memberList
    return memberList.filter((m) => (m as AdminMember).family_id === familyId)
  }, [isPlatformAdmin, memberList, familyId])

  React.useEffect(() => {
    writeHistoryHash(memberId, date)
  }, [memberId, date])

  React.useEffect(() => {
    if (!memberId) {
      setHistory(null)
      setError(null)
      setLoading(false)
      return
    }
    const { from, to } = dayBounds(date)
    let cancelled = false
    setLoading(true)
    setError(null)
    // Regular users go through the family-scoped endpoint — the same one the
    // app's day-detail screen calls; the server rejects other families.
    const load = isPlatformAdmin
      ? getMemberHistory(memberId, from, to)
      : getFamilyMemberHistory(memberId, from, to)
    load
      .then((data) => {
        if (cancelled) return
        setHistory(data)
        setLoading(false)
      })
      .catch((e) => {
        if (cancelled) return
        setHistory(null)
        setError(e instanceof Error ? e.message : 'Couldn’t load history')
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [isPlatformAdmin, memberId, date, reload])

  if ((families.loading && !families.data) || (members.loading && !members.data)) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading history…
        </div>
      </div>
    )
  }

  if (families.error || members.error) {
    return (
      <div className="wb-page">
        <ErrorState
          title="Couldn’t load members"
          description={families.error?.message ?? members.error?.message ?? 'Request failed'}
          onRetry={() => {
            families.refetch()
            members.refetch()
          }}
        />
      </div>
    )
  }

  const selected = memberList.find((m) => m.id === memberId) ?? null
  const empty = !loading && !error && history && history.trail.length === 0 && history.visits.length === 0

  return (
    <div className="wb-history">
      <div className="wb-history-toolbar">
        {isPlatformAdmin ? (
          <label className="wb-field" htmlFor="history-family">
            <span className="wb-label">Family</span>
            <select
              id="history-family"
              className="wb-select"
              value={familyId}
              onChange={(e) => {
                setFamilyId(e.target.value)
                setMemberId('')
              }}
            >
              <option value="">All families</option>
              {familyList.map((f: Family) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
            </select>
          </label>
        ) : (
          // App parity: a regular user only ever sees their own circle.
          <div className="wb-field">
            <span className="wb-label">Family</span>
            <p className="wb-history-family-name">
              <Badge tone="purple">{familyList[0]?.name ?? 'Your family'}</Badge>
            </p>
          </div>
        )}
        <label className="wb-field" htmlFor="history-member">
          <span className="wb-label">Member</span>
          <select
            id="history-member"
            className="wb-select"
            value={memberId}
            onChange={(e) => setMemberId(e.target.value)}
          >
            <option value="">Select a member</option>
            {visibleMembers.map((m) => (
              <option key={m.id} value={m.id}>
                {m.name}
              </option>
            ))}
          </select>
        </label>
        <label className="wb-field" htmlFor="history-date">
          <span className="wb-label">Day</span>
          <input
            id="history-date"
            className="wb-input"
            type="date"
            value={date}
            max={todayISO()}
            onChange={(e) => setDate(e.target.value || todayISO())}
          />
        </label>
      </div>

      <div className="wb-history-body">
        <div className="wb-history-map" aria-label="Location trail">
          {!memberId ? (
            <EmptyState
              title="Pick a member"
              description="Choose a family member to see where they went and the path they took."
            />
          ) : loading ? (
            <div className="wb-history-loading">
              <Spinner /> Loading trail…
            </div>
          ) : error ? (
            <ErrorState
              title="Couldn’t load history"
              description={error}
              onRetry={() => setReload((n) => n + 1)}
            />
          ) : empty ? (
            <EmptyState
              title="No history for this day"
              description={`${selected?.name ?? 'This member'} didn’t report any locations on this date.`}
            />
          ) : history ? (
            <HistoryMap key={`${history.user_id}-${history.from}`} history={history} />
          ) : null}
        </div>
        <aside className="wb-history-timeline" aria-label="Visit timeline">
          <h2 className="wb-history-timeline-title">
            {selected ? selected.name : 'Timeline'}
          </h2>
          {!memberId || loading ? (
            <p className="wb-history-muted">
              {loading ? 'Loading…' : 'Select a member to see visits.'}
            </p>
          ) : error ? (
            <p className="wb-history-muted">{error}</p>
          ) : !history || history.visits.length === 0 ? (
            <p className="wb-history-muted">No visits recorded.</p>
          ) : (
            <ol className="wb-history-list">
              {history.visits.map((visit, i) => (
                <li key={`${visit.arrived_at}-${i}`} className="wb-history-item">
                  <span className={`wb-history-dot is-${visit.kind}`} aria-hidden="true" />
                  <div className="wb-history-item-body">
                    <div className="wb-history-item-name">{visit.place_name}</div>
                    <div className="wb-history-item-meta">
                      {formatTime(visit.arrived_at)}
                      {formatStay(visit.arrived_at, visit.departed_at)
                        ? ` · ${formatStay(visit.arrived_at, visit.departed_at)}`
                        : ''}
                    </div>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </aside>
      </div>
    </div>
  )
}

function HistoryMap({ history }: { history: MemberHistory }) {
  const trail = (history?.trail ?? []).map((p) => [p.lat, p.lon] as [number, number])
  const visits = (history?.visits ?? []).filter((v: HistoryVisit) => v.kind !== 'transit')
  const center: [number, number] =
    trail[0] ?? (visits[0] ? [visits[0].lat, visits[0].lon] : [37.7749, -122.4194])

  return (
    <MapContainer
      className="wb-history-leaflet"
      center={center}
      zoom={13}
      minZoom={3}
      scrollWheelZoom
    >
      <BaseMapLayer />
      {trail.length >= 2 && (
        <>
          {/* White casing drawn under the colored stroke (Leaflet stacks
              later children on top) keeps the trail readable over road
              labels and dense urban tiles. */}
          <Polyline
            positions={trail}
            pathOptions={{ color: '#fff', weight: 7, opacity: 0.9 }}
          />
          <Polyline
            positions={trail}
            pathOptions={{ color: TRAIL_COLOR, weight: 4, opacity: 1 }}
          />
        </>
      )}
      {visits.map((v, i) => (
        <CircleMarker
          key={`${v.arrived_at}-${i}`}
          center={[v.lat, v.lon]}
          radius={v.kind === 'place' ? 8 : 6}
          pathOptions={{
            color: '#fff',
            weight: 2,
            fillColor: v.kind === 'place' ? TRAIL_COLOR : '#af52de',
            fillOpacity: 1,
          }}
        />
      ))}
      <FitTrail positions={trail.length >= 2 ? trail : visits.map((v) => [v.lat, v.lon] as [number, number])} />
    </MapContainer>
  )
}

function FitTrail({ positions }: { positions: [number, number][] }) {
  const map = useMap()
  React.useEffect(() => {
    if (positions.length === 0) return
    if (positions.length === 1) {
      map.setView(positions[0], 15)
      return
    }
    map.fitBounds(positions, { padding: [28, 28], maxZoom: 16 })
  }, [map, positions])
  return null
}

/** Wraps GET /family into the list shape the family filter expects. */
function familyToList(family: MyFamily): Array<Family> {
  return [{ id: family.id, name: family.name, created_at: family.created_at, member_count: 0 }]
}
