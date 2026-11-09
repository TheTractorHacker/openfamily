// The Settings section: one routed page per area, with real URLs
// (#/settings/<page>) so pages are deep-linkable and browser Back works.
// Pure data + helpers (no JSX) so they are unit-tested in test/settingsPages.

export type SettingsPageKey =
  | 'account'
  | 'appearance'
  | 'general'
  | 'server'
  | 'privacy'
  | 'security'
  | 'notifications'
  | 'backups'
  | 'integrations'
  | 'updates'

export interface SettingsPageDef {
  key: SettingsPageKey
  label: string
  /** One line under the page title. */
  description: string
  /** Sub-navigation group. */
  group: 'personal' | 'server'
  /** Server-admin pages; regular users never see them. */
  adminOnly?: boolean
  /** Extra words the command menu matches on. */
  keywords?: string
}

export const SETTINGS_BASE = '#/settings'

export const SETTINGS_GROUPS: { id: SettingsPageDef['group']; title: string }[] = [
  { id: 'server', title: 'This server' },
  { id: 'personal', title: 'Your account' },
]

export const SETTINGS_PAGES: SettingsPageDef[] = [
  {
    key: 'general',
    label: 'General',
    description: 'Domain, default units and the map style everyone sees.',
    group: 'server',
    adminOnly: true,
    keywords: 'domain dns https units miles kilometers map style tiles',
  },
  {
    key: 'server',
    label: 'Server setup',
    description: 'First-run checklist and the server’s own key for Private circles.',
    group: 'server',
    adminOnly: true,
    keywords: 'setup checklist server key processing join',
  },
  {
    key: 'privacy',
    label: 'Privacy & processing',
    description: 'Where this server runs, what is protected on disk, and defaults for new members.',
    group: 'server',
    adminOnly: true,
    keywords: 'home cloud deployment profile data key at rest members default lane',
  },
  {
    key: 'security',
    label: 'Security',
    description: 'How long sign-ins last and how many devices one person may use.',
    group: 'server',
    adminOnly: true,
    keywords: 'sessions sign-in idle devices mfa two-factor',
  },
  {
    key: 'notifications',
    label: 'Notifications',
    description: 'Text messages (SMS) for alerts and share links.',
    group: 'server',
    adminOnly: true,
    keywords: 'sms twilio text messages alerts',
  },
  {
    key: 'backups',
    label: 'Backups',
    description: 'Automatic backups of the database: schedule, where they go, encryption and Back up now.',
    group: 'server',
    adminOnly: true,
    keywords: 'backup restore s3 schedule retention encryption age',
  },
  {
    key: 'integrations',
    label: 'Integrations',
    description: 'Home Assistant and Dawarich.',
    group: 'server',
    keywords: 'home assistant dawarich webhook token',
  },
  {
    key: 'updates',
    label: 'Updates & about',
    description: 'Server and app versions, and about this server.',
    group: 'server',
    keywords: 'version update release about apk',
  },
  {
    key: 'account',
    label: 'Account',
    description: 'Your name, profile picture and password.',
    group: 'personal',
    keywords: 'profile name password picture avatar sign out',
  },
  {
    key: 'appearance',
    label: 'Appearance',
    description: 'Light or dark theme, and the app accent color.',
    group: 'personal',
    keywords: 'theme dark light color accent',
  },
]

/** Pages visible to this viewer, in navigation order. */
export function settingsPagesFor(isPlatformAdmin: boolean): SettingsPageDef[] {
  return isPlatformAdmin ? SETTINGS_PAGES : SETTINGS_PAGES.filter((p) => !p.adminOnly)
}

/** The page a bare #/settings opens. */
export function defaultSettingsPage(isPlatformAdmin: boolean): SettingsPageKey {
  return isPlatformAdmin ? 'general' : 'account'
}

export function settingsHash(key: SettingsPageKey): string {
  return `${SETTINGS_BASE}/${key}`
}

/**
 * Reads the settings page from a location hash. Returns null when the hash is
 * not a settings URL. Unknown or (for regular users) admin-only pages resolve
 * to the viewer's default page with `redirect` set, so the caller can replace
 * the URL instead of rendering a broken page. Old section names from the
 * single-page version ("data") are mapped to their new page.
 */
export function settingsPageFromHash(
  hash: string,
  isPlatformAdmin: boolean,
): { page: SettingsPageKey; redirect: boolean } | null {
  const path = hash.split('?')[0]
  if (path !== SETTINGS_BASE && !path.startsWith(`${SETTINGS_BASE}/`)) return null
  let sub = path.slice(SETTINGS_BASE.length + 1).split('/')[0] ?? ''
  if (sub === 'data') sub = 'backups'
  const visible = settingsPagesFor(isPlatformAdmin)
  const hit = visible.find((p) => p.key === sub)
  if (hit) return { page: hit.key, redirect: sub !== path.slice(SETTINGS_BASE.length + 1).split('/')[0] }
  return { page: defaultSettingsPage(isPlatformAdmin), redirect: true }
}
