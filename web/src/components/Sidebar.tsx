// Left navigation sidebar. Regular users (app-parity permissions) see only
// the routes they may use; server-admin routes stay hidden for them.

import React from 'react'
import { ROUTES, routesFor, type RouteKey } from '../lib/routes'
import { useMe } from '../lib/me'
import './nav.css'

interface SidebarProps {
  active: RouteKey
  onNavigate: (key: RouteKey) => void
  /** Optional small footer label, e.g. version. */
  footer?: React.ReactNode
}

const GROUPS: { id: string; title: string; keys: RouteKey[] }[] = [
  { id: 'overview', title: 'Overview', keys: ['dashboard', 'history'] },
  { id: 'people', title: 'People', keys: ['families', 'users', 'circles', 'sharing'] },
  { id: 'places', title: 'Places', keys: ['places'] },
  { id: 'safety', title: 'Safety', keys: ['alerts', 'activity', 'bubbles'] },
  { id: 'privacy', title: 'Privacy', keys: ['private', 'e2ee', 'audit'] },
  { id: 'health', title: 'Health', keys: ['fleet', 'system'] },
  { id: 'distribution', title: 'Distribution', keys: ['builds', 'documents'] },
  { id: 'settings', title: 'Settings', keys: ['settings'] },
]
const STORE_KEY = 'wb_nav_closed'

function loadClosed(): Record<string, boolean> {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || '{}') as Record<string, boolean>
  } catch {
    return {}
  }
}

export function Sidebar({ active, onNavigate, footer }: SidebarProps) {
  const { isPlatformAdmin } = useMe()
  const visibleRoutes = React.useMemo(
    () => (isPlatformAdmin ? ROUTES : routesFor(false)),
    [isPlatformAdmin],
  )

  const [closed, setClosed] = React.useState<Record<string, boolean>>(loadClosed)
  const toggle = (id: string) => {
    const next = { ...closed, [id]: !closed[id] }
    setClosed(next)
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(next))
    } catch {
      /* private mode: just not remembered */
    }
  }
  const groups = React.useMemo(
    () =>
      GROUPS.map((g) => ({ id: g.id, title: g.title, routes: visibleRoutes.filter((r) => g.keys.includes(r.key)) })).filter(
        (g) => g.routes.length > 0,
      ),
    [visibleRoutes],
  )

  return (
    <aside className="wb-sidebar" aria-label="Main navigation">
      <div className="wb-brand">
        <span className="wb-brand-mark" aria-hidden="true">
          <img
            className="wb-brand-icon wb-brand-icon-light"
            src="/admin/brand/orbitly-icon.svg"
            alt=""
          />
          <img
            className="wb-brand-icon wb-brand-icon-dark"
            src="/admin/brand/orbitly-icon-dark.svg"
            alt=""
          />
        </span>
        <span className="wb-brand-name">Orbitly</span>
        {isPlatformAdmin && <span className="wb-brand-sub">Admin</span>}
      </div>

      <nav className="wb-nav" aria-label="Pages">
        {groups.map((g) => {
          const collapsed = !!closed[g.id] && !g.routes.some((r) => r.key === active)
          const single = g.routes.length === 1 && g.id === 'settings'
          return (
            <div key={g.id} className={`wb-nav-group${collapsed ? ' is-collapsed' : ''}`}>
              {!single && (
                <button type="button" className="wb-nav-group-head" aria-expanded={!collapsed}
                  onClick={() => toggle(g.id)}>
                  <span>{g.title}</span>
                  <span className="wb-nav-group-chev" aria-hidden="true">{collapsed ? '›' : '⌄'}</span>
                </button>
              )}
              {g.routes.map((r) => {
                const isActive = r.key === active
                return (
                  <a
                    key={r.key}
                    href={r.hash}
                    className={`wb-nav-item ${isActive ? 'is-active' : ''}`}
                    aria-current={isActive ? 'page' : undefined}
                    title={r.label}
                    onClick={(e) => {
                      e.preventDefault()
                      onNavigate(r.key)
                    }}
                  >
                    <span className="wb-nav-icon">{r.icon}</span>
                    <span className="wb-nav-label">{r.label}</span>
                    {isActive && <span className="wb-nav-active-bar" aria-hidden="true" />}
                  </a>
                )
              })}
            </div>
          )
        })}
      </nav>

      {footer && <div className="wb-sidebar-footer">{footer}</div>}
    </aside>
  )
}
