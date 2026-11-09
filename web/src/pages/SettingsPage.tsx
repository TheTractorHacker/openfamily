// Settings — a section of dedicated pages (General, Server setup, Privacy &
// processing, Security, Notifications, Backups, Integrations, Updates &
// about, Account, Appearance), each with its own URL (#/settings/<page>), a
// left sub-navigation with the active page marked, and one consistent header.
// Server-admin pages are hidden for regular users, who keep the personal
// pages the apps also offer. Each card keeps its own Save button; leaving a
// page with unsaved changes asks first (lib/unsaved).

import React from 'react'
import { useMe } from '../lib/me'
import { useServerVersion } from '../lib/serverVersion'
import {
  SETTINGS_GROUPS,
  settingsHash,
  settingsPageFromHash,
  settingsPagesFor,
  type SettingsPageDef,
  type SettingsPageKey,
} from '../lib/settingsPages'
import { useHasUnsaved } from '../lib/unsaved'
import { ThemeToggle } from '../components/ThemeToggle'
import { Card, CopyButton, Mono } from '../components/primitives'
import { ServerVersionCard } from './ServerVersionCard'
import { AppVersionsCard } from './AppVersionsCard'
import { AboutCard } from './AboutCard'
import { TwilioSettingsCard } from './TwilioSettingsCard'
import { DawarichSettingsCard } from './DawarichSettingsCard'
import { IntegrationsCard } from './IntegrationsCard'
import { ThemeAccentCard } from './ThemeAccentCard'
import { UnitsDefaultCard } from './UnitsDefaultCard'
import { DeploymentProfileCard, ServerSetupCard } from './ServerSetupCard'
import { DomainSettingsCard } from './DomainSettingsCard'
import { MapStyleCard } from './MapStyleCard'
import { MemberDefaultsCard, SessionSecurityCard } from './SecurityCards'
import { BackupsCard } from './BackupsCard'
import { AccountSettings } from './AccountSettings'
import './pages.css'
import './SettingsPage.css'

interface SettingsPageProps {
  /** Current location hash (owned by App so Back/Forward stay in sync). */
  hash: string
  /** Opens a hash after the unsaved-changes check. */
  onOpen: (hash: string) => void
  email: string | null
  onLogout: () => void
}

export function SettingsPage({ hash, onOpen, email, onLogout }: SettingsPageProps) {
  const { isPlatformAdmin } = useMe()
  const resolved = settingsPageFromHash(hash, isPlatformAdmin) ?? { page: 'account' as SettingsPageKey, redirect: true }
  const pages = settingsPagesFor(isPlatformAdmin)
  const current = pages.find((p) => p.key === resolved.page) ?? pages[0]

  // #/settings (or an unknown page) shows the default page; rewrite the
  // address in place so Back does not bounce through the bare URL.
  React.useEffect(() => {
    if (resolved.redirect) window.history.replaceState(null, '', settingsHash(resolved.page))
  }, [resolved.redirect, resolved.page])

  // Move focus to the new page title on sub-page changes (not on first load),
  // so keyboard and screen-reader users land on the content they opened.
  const titleRef = React.useRef<HTMLHeadingElement>(null)
  const firstRender = React.useRef(true)
  React.useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false
      return
    }
    titleRef.current?.focus()
    document.getElementById('wb-content')?.scrollTo?.({ top: 0 })
  }, [current.key])

  React.useEffect(() => {
    const prev = document.title
    document.title = `${current.label} · Settings · Orbitly`
    return () => {
      document.title = prev
    }
  }, [current.label])

  return (
    <div className="wb-page wb-settings-page">
      <div className="wb-settings-layout">
        <SettingsSubnav pages={pages} active={current.key} onOpen={onOpen} />
        <div className="wb-settings-main">
          <SettingsHeader page={current} titleRef={titleRef} />
          <div className="wb-settings-stack" data-settings-page={current.key}>
            <SettingsContent page={current.key} isPlatformAdmin={isPlatformAdmin} email={email} onLogout={onLogout} />
          </div>
        </div>
      </div>
    </div>
  )
}

function SettingsSubnav({
  pages,
  active,
  onOpen,
}: {
  pages: SettingsPageDef[]
  active: SettingsPageKey
  onOpen: (hash: string) => void
}) {
  return (
    <nav className="wb-settings-subnav" aria-label="Settings pages">
      <p className="wb-settings-subnav-title">Settings</p>
      {SETTINGS_GROUPS.map((g) => {
        const items = pages.filter((p) => p.group === g.id)
        if (items.length === 0) return null
        return (
          <div key={g.id} className="wb-settings-subnav-group">
            <p className="wb-settings-subnav-head" id={`wb-settings-group-${g.id}`}>
              {g.title}
            </p>
            <ul aria-labelledby={`wb-settings-group-${g.id}`}>
              {items.map((p) => {
                const on = p.key === active
                return (
                  <li key={p.key}>
                    <a
                      href={settingsHash(p.key)}
                      className={`wb-settings-subnav-item${on ? ' is-active' : ''}`}
                      aria-current={on ? 'page' : undefined}
                      onClick={(e) => {
                        // Let modified clicks open a new tab as usual.
                        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return
                        e.preventDefault()
                        onOpen(settingsHash(p.key))
                      }}
                    >
                      {p.label}
                    </a>
                  </li>
                )
              })}
            </ul>
          </div>
        )
      })}
    </nav>
  )
}

function SettingsHeader({ page, titleRef }: { page: SettingsPageDef; titleRef: React.RefObject<HTMLHeadingElement> }) {
  const unsaved = useHasUnsaved()
  return (
    <div className="wb-page-header wb-settings-header">
      <div className="wb-page-header-text">
        <p className="wb-settings-crumb">
          <a href="#/settings">Settings</a>
          <span aria-hidden="true"> / </span>
          <span>{page.group === 'personal' ? 'Your account' : 'This server'}</span>
        </p>
        <h1 className="wb-page-title" ref={titleRef} tabIndex={-1}>
          {page.label}
        </h1>
        <p className="wb-page-subtitle">{page.description}</p>
      </div>
      {unsaved && (
        <span className="wb-settings-unsaved" role="status">
          Unsaved changes
        </span>
      )}
    </div>
  )
}

function SettingsContent({
  page,
  isPlatformAdmin,
  email,
  onLogout,
}: {
  page: SettingsPageKey
  isPlatformAdmin: boolean
  email: string | null
  onLogout: () => void
}) {
  switch (page) {
    case 'general':
      return (
        <>
          <DomainSettingsCard />
          <UnitsDefaultCard />
          <MapStyleCard />
        </>
      )
    case 'server':
      return (
        <>
          <p className="wb-settings-intro">
            The checklist below disappears once the server is set up; the server&rsquo;s key and the advanced
            &ldquo;separate container&rdquo; route stay under <em>Details</em>.
          </p>
          <ServerSetupCard />
        </>
      )
    case 'privacy':
      return (
        <>
          <DeploymentProfileCard />
          <MemberDefaultsCard />
        </>
      )
    case 'security':
      return (
        <>
          <SessionSecurityCard />
          <Card>
            <h3 className="wb-settings-title">Sign-ins and the audit log</h3>
            <p className="wb-settings-section-help wb-settings-help-flush">
              See who is signed in where, sign devices out, and read the audit log on{' '}
              <a href="#/audit">Audit &amp; sessions</a>. Two-factor sign-in is turned on per person in the Orbitly app
              (Settings, Security).
            </p>
          </Card>
        </>
      )
    case 'notifications':
      return <TwilioSettingsCard />
    case 'backups':
      return <BackupsCard title="Status" />
    case 'integrations':
      return (
        <>
          {isPlatformAdmin && <DawarichSettingsCard />}
          <IntegrationsCard />
        </>
      )
    case 'updates':
      return (
        <>
          {isPlatformAdmin && <ServerVersionCard />}
          {isPlatformAdmin && <AppVersionsCard />}
          <ThisServerCard />
          <AboutCard />
        </>
      )
    case 'appearance':
      return (
        <>
          <Card>
            <h3 className="wb-settings-title">Theme</h3>
            <p className="wb-settings-section-help">System follows this device. Light is Ice. Dark is Night.</p>
            <ThemeToggle />
          </Card>
          {isPlatformAdmin && <ThemeAccentCard />}
        </>
      )
    case 'account':
    default:
      return <AccountSettings email={email} onLogout={onLogout} />
  }
}

function ThisServerCard() {
  const serverVersion = useServerVersion()
  const serverUrl = typeof window !== 'undefined' ? window.location.origin : '—'
  return (
    <Card>
      <h3 className="wb-settings-title">This server</h3>
      <dl className="wb-settings-list wb-settings-list-row">
        <div>
          <dt>App</dt>
          <dd>Orbitly</dd>
        </div>
        <div>
          <dt>Version</dt>
          <dd>{serverVersion ?? '…'}</dd>
        </div>
        <div>
          <dt>Server</dt>
          <dd className="wb-settings-mono">
            <Mono>{serverUrl}</Mono>
            <CopyButton value={serverUrl} label="Copy server URL" />
          </dd>
        </div>
      </dl>
    </Card>
  )
}
