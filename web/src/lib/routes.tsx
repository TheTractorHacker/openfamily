// Route definitions shared by Sidebar, TopBar, and App.

import React from 'react'

export type RouteKey =
  | 'dashboard'
  | 'history'
  | 'families'
  | 'users'
  | 'places'
  | 'circles'
  | 'sharing'
  | 'activity'
  | 'bubbles'
  | 'audit'
  | 'alerts'
  | 'system'
  | 'builds'
  | 'settings'

export interface RouteDef {
  key: RouteKey
  label: string
  /** Inline SVG icon, 20x20, inherits currentColor. */
  icon: React.ReactNode
  /** Hash fragment used for navigation. */
  hash: string
  /**
   * Server-admin surfaces backed by /api/admin/*. Regular users (whose
   * permissions mirror the mobile apps) never see these routes.
   */
  adminOnly?: boolean
}

const icon = (path: React.ReactNode): React.ReactNode => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
    {path}
  </svg>
)

export const ROUTES: RouteDef[] = [
  {
    key: 'dashboard',
    label: 'Dashboard',
    hash: '#/dashboard',
    icon: icon(
      <path
        d="M4 13.5 12 5l8 8.5M6 12v7h12v-7"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'history',
    label: 'History',
    hash: '#/history',
    icon: icon(
      <path
        d="M12 7v5l3 2M12 21a9 9 0 1 0-6.3-2.6L4 21l.5-3.5"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'families',
    label: 'Families',
    hash: '#/families',
    icon: icon(
      <path
        d="M16 11a3 3 0 1 0-2.6-4.5M8 11a3 3 0 1 1 2.6-4.5M3 20c0-2.8 2-5 4.5-5h9C19 15 21 17.2 21 20M8 15a2.5 2.5 0 1 1 5 0"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'users',
    label: 'Users',
    hash: '#/users',
    adminOnly: true,
    icon: icon(
      <path
        d="M12 11.5a3.25 3.25 0 1 0-3.25-3.25A3.25 3.25 0 0 0 12 11.5ZM5 20c0-3.1 3.1-5.5 7-5.5s7 2.4 7 5.5"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'places',
    label: 'Places',
    hash: '#/places',
    adminOnly: true,
    icon: icon(
      <path
        d="M12 21s6.5-5.6 6.5-11a6.5 6.5 0 1 0-13 0C5.5 15.4 12 21 12 21Zm0-8.2a2.6 2.6 0 1 0 0-5.2 2.6 2.6 0 0 0 0 5.2Z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'circles',
    label: 'Circles & invites',
    hash: '#/circles',
    adminOnly: true,
    icon: icon(
      <path
        d="M9 12a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm6.5 1a2.5 2.5 0 1 0 0-5M3 19c0-2.8 2.7-5 6-5s6 2.2 6 5M16 14.2c2.7.2 5 1.9 5 4.8"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'sharing',
    label: 'Share links',
    hash: '#/sharing',
    adminOnly: true,
    icon: icon(
      <path
        d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3A4 4 0 0 0 11 18.7l1-1"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'activity',
    label: 'Activity',
    hash: '#/activity',
    adminOnly: true,
    icon: icon(
      <path
        d="M3 12h4l2.5-6 4 12 2.5-6H21"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'bubbles',
    label: 'Bubbles',
    hash: '#/bubbles',
    adminOnly: true,
    icon: icon(
      <path
        d="M9.5 15a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11Zm7 5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'audit',
    label: 'Audit & sessions',
    hash: '#/audit',
    adminOnly: true,
    icon: icon(
      <path
        d="M12 3 5 6v5.5c0 4.3 2.8 7.6 7 9.5 4.2-1.9 7-5.2 7-9.5V6l-7-3Zm-2.5 9 2 2 3.5-4"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'alerts',
    label: 'Alerts & SOS',
    hash: '#/alerts',
    adminOnly: true,
    icon: icon(
      <path
        d="M12 4 3 19h18L12 4Zm0 5.5v4.5m0 2.5v.01"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'system',
    label: 'System health',
    hash: '#/system',
    adminOnly: true,
    icon: icon(
      <path
        d="M4 13h3l2-5 4 10 2-5h5M4 5h16v14H4z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'builds',
    label: 'Builds',
    hash: '#/builds',
    adminOnly: true,
    icon: icon(
      <path
        d="M12 3v9m0 0 3-3m-3 3L9 9M5 17v2a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    key: 'settings',
    label: 'Settings',
    hash: '#/settings',
    icon: icon(
      <path
        d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Zm7 3.5a7 7 0 0 0-.1-1.1l1.7-1.3-1.7-3-2 .8a7 7 0 0 0-1.9-1.1L14.6 4h-3.4l-.4 2.3a7 7 0 0 0-1.9 1.1l-2-.8-1.7 3 1.7 1.3A7 7 0 0 0 6.6 12a7 7 0 0 0 .1 1.1l-1.7 1.3 1.7 3 2-.8a7 7 0 0 0 1.9 1.1l.4 2.3h3.4l.4-2.3a7 7 0 0 0 1.9-1.1l2 .8 1.7-3-1.7-1.3c.06-.36.1-.73.1-1.1Z"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
]

export const DEFAULT_ROUTE: RouteKey = 'dashboard'

/** Routes visible to the given viewer. Platform admins see everything. */
export function routesFor(isPlatformAdmin: boolean): RouteDef[] {
  return isPlatformAdmin ? ROUTES : ROUTES.filter((r) => !r.adminOnly)
}

export function routeFromHash(hash: string): RouteKey {
  const path = hash.split('?')[0]
  const match = ROUTES.find((r) => path === r.hash || path.startsWith(`${r.hash}/`))
  return match ? match.key : DEFAULT_ROUTE
}