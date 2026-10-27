// Top bar — page title, contextual actions, and the account menu.

import React from 'react'
import { ROUTES, type RouteKey } from '../lib/routes'
import { useMe } from '../lib/me'
import { CommandMenu } from './CommandMenu'
import { ThemeCycleButton } from './ThemeCycleButton'
import './nav.css'

interface TopBarProps {
  active: RouteKey
  /** Optional right-side actions slot. */
  actions?: React.ReactNode
  onLogout: () => void
  /** Email shown in the account chip. */
  email?: string | null
  /** Navigate to a route (used by the ⌘K command menu). */
  onNavigate: (key: RouteKey) => void
}

export function TopBar({ active, actions, onLogout, email, onNavigate }: TopBarProps) {
  const route = ROUTES.find((r) => r.key === active)
  const { isPlatformAdmin } = useMe()
  const [menuOpen, setMenuOpen] = React.useState(false)
  const menuRef = React.useRef<HTMLDivElement>(null)

  React.useEffect(() => {
    if (!menuOpen) return
    const onDown = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false)
      }
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [menuOpen])

  const initials = (email ?? '?').slice(0, 1).toUpperCase()

  return (
    <header className="wb-topbar">
      <div className="wb-topbar-left">
        <span className="wb-topbar-title">{route?.label ?? 'OpenFamily'}</span>
      </div>

      {/* The ⌘K search corpus comes from the server-wide admin endpoints, so
          it is only offered to platform admins. */}
      {isPlatformAdmin && <CommandMenu onNavigate={onNavigate} />}

      <div className="wb-topbar-right">
        {actions}

        <ThemeCycleButton />

        <div className="wb-account" ref={menuRef}>
          <button
            type="button"
            className="wb-account-btn"
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            onClick={() => setMenuOpen((o) => !o)}
          >
            <span className="wb-account-avatar" aria-hidden="true">{initials}</span>
            <span className="wb-account-email">{email ?? 'Account'}</span>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <path d="m6 9 6 6 6-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
          {menuOpen && (
            <div className="wb-account-menu" role="menu">
              <button
                type="button"
                className="wb-account-menu-item"
                role="menuitem"
                onClick={() => {
                  setMenuOpen(false)
                  onLogout()
                }}
              >
                Sign out
              </button>
            </div>
          )}
        </div>
      </div>
    </header>
  )
}