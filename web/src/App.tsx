// App root — auth gate + hash routing + the authenticated shell.
//
// When unauthenticated: render the login screen.
// When authenticated: render the sidebar + top bar shell with the active page.
//
// Permissions mirror the mobile apps: regular users see Dashboard, History,
// Families, and Settings scoped to their own circle; Users and Builds are
// platform-admin surfaces and are hidden (and blocked) for everyone else.

import React from 'react'
import { Sidebar } from './components/Sidebar'
import { TopBar } from './components/TopBar'
import { LoginPage } from './pages/LoginPage'
import { FamiliesPage } from './pages/FamiliesPage'
import { UsersPage } from './pages/UsersPage'
import { BuildsPage } from './pages/BuildsPage'
import { ActivityPage } from './pages/ActivityPage'
import { BubblesPage } from './pages/BubblesPage'
import { AuditPage } from './pages/AuditPage'
import { AlertsPage } from './pages/AlertsPage'
import { SystemPage } from './pages/SystemPage'
import { SettingsPage } from './pages/SettingsPage'
import { CirclesPage } from './pages/CirclesPage'
import { ShareLinksPage } from './pages/ShareLinksPage'
import { ROUTES, DEFAULT_ROUTE, routeFromHash, type RouteKey } from './lib/routes'
import { clearTokens, getEmail, isAuthenticated, subscribeAuth } from './lib/auth'
import { useMe } from './lib/me'
import { useServerVersion } from './lib/serverVersion'
import { AccessDenied, Spinner } from './components/primitives'
import './shell.css'

// Map pages pull in Leaflet/MapLibre; load them on demand so login and the
// other pages stay light.
const DashboardPage = React.lazy(() =>
  import('./pages/DashboardPage').then((m) => ({ default: m.DashboardPage })),
)
const PlacesPage = React.lazy(() =>
  import('./pages/PlacesPage').then((m) => ({ default: m.PlacesPage })),
)
const HistoryPage = React.lazy(() =>
  import('./pages/HistoryPage').then((m) => ({ default: m.HistoryPage })),
)

export default function App() {
  // Re-render when auth changes (login, logout, cross-tab, failed refresh).
  const [, force] = React.useReducer((n: number) => n + 1, 0)
  React.useEffect(() => subscribeAuth(force), [force])

  // Identity + capability flags for the signed-in account.
  const { me, loading: meLoading, isPlatformAdmin } = useMe()
  const adminMfaRequired = me?.admin_mfa_required === true
  const serverVersion = useServerVersion()

  // Hash-based routing.
  const [route, setRoute] = React.useState<RouteKey>(() =>
    routeFromHash(typeof window !== 'undefined' ? window.location.hash : ''),
  )
  React.useEffect(() => {
    const onHash = () => setRoute(routeFromHash(window.location.hash))
    window.addEventListener('hashchange', onHash)
    // Ensure a sensible default hash on first load.
    if (!window.location.hash) window.location.hash = `#/${DEFAULT_ROUTE}`
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const navigate = React.useCallback((key: RouteKey) => {
    const hash = `#/${key}`
    if (window.location.hash !== hash) window.location.hash = hash
    setRoute(key)
  }, [])

  const logout = React.useCallback(() => {
    clearTokens()
  }, [])

  if (!isAuthenticated()) {
    return <LoginPage onLoggedIn={() => {}} />
  }

  const email = getEmail()

  return (
    <div className="wb-shell">
      <div className="wb-shell-sidebar">
        <Sidebar active={route} onNavigate={navigate} footer={<span>{serverVersion ?? ''}</span>} />
      </div>
      <div className="wb-shell-topbar">
        <TopBar active={route} onLogout={logout} email={email} onNavigate={navigate} />
      </div>
      <main className="wb-shell-content" id="wb-content">
        {meLoading ? (
          <div className="wb-page">
            <div className="wb-page-loading">
              <Spinner /> Loading your account…
            </div>
          </div>
        ) : (
          <React.Suspense
            fallback={
              <div className="wb-page">
                <div className="wb-page-loading">
                  <Spinner /> Loading…
                </div>
              </div>
            }
          >
            {renderPage(route, email, logout, isPlatformAdmin, adminMfaRequired)}
          </React.Suspense>
        )}
      </main>
    </div>
  )
}

function renderPage(
  route: RouteKey,
  email: string | null,
  logout: () => void,
  isPlatformAdmin: boolean,
  adminMfaRequired: boolean,
): React.ReactNode {
  // Server-admin routes stay blocked for regular users, even via deep links.
  const adminOnly = ROUTES.find((r) => r.key === route)?.adminOnly ?? false
  if (adminOnly && isPlatformAdmin && adminMfaRequired) {
    return (
      <div className="wb-page">
        <AccessDenied message="This server requires two-factor authentication for administrators. Turn it on in the OpenFamily app (Settings, Security), then sign in again to use the admin panel." />
      </div>
    )
  }
  if (adminOnly && !isPlatformAdmin) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  switch (route) {
    case 'dashboard':
      return <DashboardPage />
    case 'history':
      return <HistoryPage />
    case 'families':
      return <FamiliesPage />
    case 'users':
      return <UsersPage />
    case 'places':
      return <PlacesPage />
    case 'circles':
      return <CirclesPage />
    case 'sharing':
      return <ShareLinksPage />
    case 'activity':
      return <ActivityPage />
    case 'bubbles':
      return <BubblesPage />
    case 'audit':
      return <AuditPage />
    case 'alerts':
      return <AlertsPage />
    case 'system':
      return <SystemPage />
    case 'builds':
      return <BuildsPage />
    case 'settings':
      return <SettingsPage email={email} onLogout={logout} />
    default:
      return <DashboardPage />
  }
}