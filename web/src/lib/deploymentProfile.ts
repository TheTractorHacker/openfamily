// Pure helpers for the "Where does this server run?" card and the first-run
// "Server setup" checklist. No React, no network: unit-tested in test/.

export type ProfileChoice = 'home' | 'cloud'

export type DeploymentState = {
  /** The configured profile; '' while nobody chose. */
  profile: ProfileChoice | ''
  /** What the server and the apps act on: unset counts as cloud. */
  effective: ProfileChoice
  source: 'admin' | 'env' | 'unset'
  recommended_lane: 'server' | 'phone'
  token_configured: boolean
  server_pinned: boolean
  setup_dismissed: boolean
  circles_with_server?: number
  server_device: null | { device_id: string; label: string; fingerprint: string; short: string; digits: string }
  at_rest: {
    key_configured: boolean
    protected_columns: string[]
    locations_encrypted: boolean
    disk_encryption_known: boolean
  }
  backups?: { last_run_at: string; last_status: string; last_encrypted: boolean }
  docs_path: string
  /** The API's own server device (absent on older servers or with the separate sidecar). */
  builtin?: {
    state: 'waiting_for_approval' | 'running' | 'idle' | 'stopped' | 'error'
    state_detail?: string
    registered: boolean
    short: string
    digits: string
    fingerprint: string
    sealed: boolean
    last_sync?: string
  }
  server_device_builtin?: boolean
  private_circles_without_server?: number
}

/** One sentence per profile, in the words a family uses. */
export function profileSummary(effective: ProfileChoice, chosen: boolean): string {
  if (effective === 'home') {
    return 'The server runs on a computer you own. The app will offer to let it see locations first, because nobody else can reach the disk.'
  }
  return chosen
    ? 'The server is rented or hosted. The company that runs the machine could read what the server can read, so the app keeps location on phones unless someone deliberately adds the server.'
    : 'Not chosen yet. Until you choose, the server is treated as rented (the careful setting) and the app keeps location on phones.'
}

export function cloudWarnings(s: Pick<DeploymentState, 'effective' | 'at_rest' | 'backups'>): string[] {
  if (s.effective !== 'cloud') return []
  const out: string[] = []
  if (!s.at_rest.key_configured) {
    out.push('No data key is set (OPENFAMILY_DATA_KEY), so stored secrets such as the SMS token are not encrypted in the database.')
  }
  if (s.backups && !s.backups.last_encrypted) {
    out.push('The last backup was not encrypted. On a rented server an unencrypted backup can be read by the host.')
  }
  return out
}

export type SetupStep = { key: string; title: string; done: boolean; detail: string }

/** True when the server is enrolled (built-in or sidecar) and its key is pinned. */
export function serverApproved(s: DeploymentState | null): boolean {
  return !!s && s.server_pinned
}

/** The three first-run steps. Each completes from server state, not from clicks. */
export function setupSteps(s: DeploymentState | null): SetupStep[] {
  const chosen = !!s && s.profile !== ''
  return [
    { key: 'profile', title: 'Pick where the server runs', done: chosen, detail: 'At home or rented. This sets what the app suggests.' },
    {
      key: 'approve',
      title: 'Approve on your phone',
      done: serverApproved(s),
      detail: 'Your phone asks "Your server wants to join". Check the code matches and tap Approve.',
    },
    {
      key: 'apps',
      title: 'Install the apps and invite your people',
      done: !!s && (s.circles_with_server ?? 0) > 0,
      detail: 'Download the app, create a circle and share the invite code.',
    },
  ]
}

export function setupComplete(s: DeploymentState | null): boolean {
  return setupSteps(s).every((x) => x.done)
}

/** The server is up and doing the processing: show the green state instead of the steps. */
export function serverProcessing(s: DeploymentState | null): boolean {
  return setupComplete(s)
}

/** Show the checklist for a new install until it is finished or dismissed. */
export function showSetupCard(s: DeploymentState | null): boolean {
  return !!s && !s.setup_dismissed && !setupComplete(s)
}

/** What the QR (and the "copy" button) carry: the same text format as the phones' key screens. */
export function qrText(digits: string): string {
  return 'Orbitly server key\n' + digits
}

/** The documented sidecar enrollment (Details > advanced; not part of the main flow), as copy-paste lines (see docker-compose.yml). */
export function enrollCommands(email: string): { token: string; request: string; approve: string; start: string } {
  const who = email.trim() === '' ? 'you@example.org' : email.trim()
  return {
    token: 'echo "E2EE_SERVER_INGEST_TOKEN=$(openssl rand -hex 32)" >> .env && echo "COMPOSE_PROFILES=${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}e2ee-server" >> .env && docker compose up -d',
    request: `read -rsp 'Your Orbitly password: ' P; echo; printf '%s\\n' "$P" | docker compose --profile e2ee-server run --rm -T e2ee-server-device enroll --kind server --server http://api:8080 --email ${who}`,
    approve: 'docker compose --profile e2ee-server run --rm e2ee-server-device enroll --approval PASTE_THE_APPROVAL_CODE_HERE',
    start: 'docker compose --profile e2ee-server up -d e2ee-server-device',
  }
}
