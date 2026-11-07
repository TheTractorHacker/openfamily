// Dashboard / live map page. The map is full-bleed within the content region.
// A slim stat strip sits above it; both fill the available content height.
//
// Permissions mirror the mobile apps: platform admins see server-wide stats,
// everyone else sees their own circle via the same family endpoints the apps
// use — never the admin API.

import React from 'react'
import { getMyFamily, listAllMembers, listFamilies, listMyFamilyMembers } from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { useMe } from '../lib/me'
import type { Family, MyFamily } from '../lib/types'
import { MapArea } from '../components/MapArea'
import { Badge, Card, EmptyState, Spinner, Button } from '../components/primitives'
import './pages.css'
import { ServerProcessingPanel } from './ServerProcessingPanel'
import './DashboardPage.css'

export function DashboardPage() {
  const { isPlatformAdmin, loading: meLoading } = useMe()

  // Platform admins read the server-wide admin API; regular users read their
  // own family, exactly like the app's map screen.
  const families = useAsync(
    () => (isPlatformAdmin ? listFamilies() : getMyFamily().then(familyToList)),
    [isPlatformAdmin],
  )
  const members = useAsync(
    () => (isPlatformAdmin ? listAllMembers() : listMyFamilyMembers()),
    [isPlatformAdmin],
  )

  const familyName =
    !isPlatformAdmin && families.data && families.data.length > 0
      ? families.data[0]!.name
      : null
  const totalFamilies = families.data?.length ?? 0
  const totalMembers = members.data?.length ?? 0
  const online = React.useMemo(() => {
    const now = Date.now()
    const list = members.data ?? []
    return list.filter((m) => {
      if (!m.ts) return false
      const age = now - new Date(m.ts).getTime()
      return age < 5 * 60 * 1000
    }).length
  }, [members.data])

  // A regular user without a circle can still act — the app lets them create
  // or join one from this state rather than showing an error.
  const noFamily =
    !meLoading &&
    !isPlatformAdmin &&
    !families.loading &&
    families.error?.status === 404

  if (noFamily) {
    return (
      <div className="wb-page">
        <Card>
          <EmptyState
            title="You’re not in a circle yet"
            description="Create a new circle or join one with an invite code — then your people show up here live."
            action={
              <Button size="sm" onClick={() => navigateToFamilies()}>
                Set up your circle
              </Button>
            }
          />
        </Card>
      </div>
    )
  }

  const loading = meLoading || families.loading || members.loading
  const empty = !loading && totalFamilies === 0 && totalMembers === 0

  return (
    <div className="wb-dashboard">
      <div className="wb-dashboard-strip">
        <div className="wb-dashboard-stats">
          {isPlatformAdmin ? (
            <StatCard label="Groups" value={loading ? null : totalFamilies} />
          ) : (
            <StatCard label="Your circle" value={loading ? null : familyName ?? '—'} />
          )}
          <StatCard label="Members" value={loading ? null : totalMembers} />
          <StatCard
            label="Live now"
            value={loading ? null : online}
            hint={loading ? undefined : 'Updated in the last 5 minutes'}
            accent="green"
          />
        </div>
        <div className="wb-dashboard-status">
          {loading ? (
            <span className="wb-dashboard-status-loading">
              <Spinner size={14} /> Loading…
            </span>
          ) : families.error || members.error ? (
            <Badge tone="red" dot>
              Connection error
            </Badge>
          ) : (
            <Badge tone="green" dot>
              Streaming
            </Badge>
          )}
        </div>
      </div>

      <div className="wb-dashboard-map">
        <Card padded={false} className="wb-dashboard-mapcard">
          {empty ? (
            <EmptyState
              title="No groups yet"
              description="Create a circle in the app and its members will appear here on the live map."
            />
          ) : (
            <MapArea />
          )}
        </Card>
      </div>
      {isPlatformAdmin && <ServerProcessingPanel />}
    </div>
  )
}

/** Wraps GET /family (404 when familyless) into the list shape the strip expects. */
function familyToList(family: MyFamily): Family[] {
  return [{ id: family.id, name: family.name, created_at: family.created_at, member_count: 0 }]
}

function navigateToFamilies(): void {
  if (typeof window !== 'undefined') window.location.hash = '#/families'
}

interface StatCardProps {
  label: string
  value: number | string | null
  hint?: string
  accent?: 'green' | 'purple'
}

function StatCard({ label, value, hint, accent }: StatCardProps) {
  const valueClass = accent === 'green' ? ' wb-stat-value-green' : accent === 'purple' ? ' wb-stat-value-purple' : ''
  return (
    <Card className="wb-dashboard-stat">
      <div className="wb-stat-label">{label}</div>
      <div className={`wb-stat-value${valueClass}`}>
        {value === null ? <span className="wb-stat-skeleton" /> : value}
      </div>
      {hint && <div className="wb-stat-hint">{hint}</div>}
    </Card>
  )
}
