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

export function Sidebar({ active, onNavigate, footer }: SidebarProps) {
  const { isPlatformAdmin } = useMe()
  const visibleRoutes = React.useMemo(
    () => (isPlatformAdmin ? ROUTES : routesFor(false)),
    [isPlatformAdmin],
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

      <nav className="wb-nav">
        {visibleRoutes.map((r) => {
          const isActive = r.key === active
          return (
            <a
              key={r.key}
              href={r.hash}
              className={`wb-nav-item ${isActive ? 'is-active' : ''}`}
              aria-current={isActive ? 'page' : undefined}
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
      </nav>

      {footer && <div className="wb-sidebar-footer">{footer}</div>}
    </aside>
  )
}
