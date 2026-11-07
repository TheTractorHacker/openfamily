// Pure helpers for the "Trust this server by default" card.

export type TrustedDefaultState = {
  trusted_server_default: boolean
  token_configured: boolean
  server_device_pinned: boolean
}

/** Why the toggle cannot be switched on, or null when it can. */
export function trustedDefaultBlocker(s: Pick<TrustedDefaultState, 'token_configured' | 'server_device_pinned'>): string | null {
  if (!s.token_configured) {
    return 'Not set up: the server has no E2EE_SERVER_INGEST_TOKEN. Enable the trusted-server sidecar first (see docs/design/E2EE.md).'
  }
  if (!s.server_device_pinned) {
    return 'Not set up: no server device is pinned yet. Enroll the server device from a phone first.'
  }
  return null
}

/** Switching OFF is always allowed, so a stale "on" can never get stuck. */
export function trustedDefaultCanToggle(s: TrustedDefaultState): boolean {
  return s.trusted_server_default || trustedDefaultBlocker(s) === null
}
