// Shared API types for the Orbitly admin panel.
// Mirrors the backend contract documented in the task brief.

export type Role = 'admin' | 'member' | 'child'

export type MotionState =
  | 'stationary'
  | 'walking'
  | 'running'
  | 'cycling'
  | 'driving'
  | 'unknown'

export interface LoginResponse {
  access_token: string
  refresh_token: string
  token_type: string
  expires_in: number
}

/** The authenticated user's account details. */
export interface Profile {
  id: string
  name: string
  email: string
  role: Role
  has_avatar: boolean
  avatar_updated_at: string | null
  avatar_version: number
}

export interface Family {
  id: string
  name: string
  created_at: string
  member_count: number
}

/** The signed-in account as returned by GET /me (includes capability flags). */
export interface Me extends Profile {
  family_id: string | null
  phone?: string | null
  /** True when the account may use the server-admin surfaces (/api/admin/*). */
  platform_admin: boolean
  /** True when two-factor is required for admins and this admin has none. */
  admin_mfa_required?: boolean
  created_at?: string
  updated_at?: string
}

/**
 * The caller's own family as returned by GET /family — includes the caller's
 * role within that family so the UI can gate admin-only actions the same way
 * the mobile apps do.
 */
export interface MyFamily {
  id: string
  name: string
  created_at: string
  role: Role
  user_id: string
}

/** Account as returned by GET /api/admin/users — includes users with no family. */
export interface AdminUser {
  id: string
  family_id: string | null
  family_name: string | null
  email: string
  name: string
  phone: string | null
  role: Role
  platform_admin: boolean
  created_at: string
  updated_at: string
}

export interface Member {
  id: string
  name: string
  email: string
  role: Role
  lat: number | null
  lon: number | null
  ts: string | null
  battery_pct: number | null
  speed_mps: number | null
  motion_state: MotionState | null
  accuracy_meters: number | null
  /** Whether the member has an avatar available from the private admin endpoint. */
  has_avatar?: boolean
  /** Timestamp retained for display compatibility. */
  avatar_updated_at?: string | null
  /** Durable revision that changes on every avatar upload or removal. */
  avatar_version?: number
}

/** Member as returned by GET /api/admin/members — tagged with its family. */
export interface AdminMember extends Member {
  family_id: string
  family_name: string
}

/** Invite code as returned by the admin invite endpoints. */
export interface InviteCode {
  id: string
  code: string
  family_id: string
  created_by: string | null
  role: Role
  max_uses: number
  uses: number
  expires_at: string | null
  created_at: string
}

/** Invite code tagged with its family name (GET /api/admin/invites). */
export interface AdminInvite extends InviteCode {
  family_name: string
  circle_id?: string | null
  circle_name?: string | null
}

/** A circle from GET /api/admin/circles. */
export interface AdminCircle {
  id: string
  name: string
  icon: string | null
  created_by: string | null
  creator_name: string | null
  created_at: string
  expires_at: string | null
  ended_at: string | null
  member_count: number
  family_backed: boolean
  status: 'permanent' | 'active' | 'expired' | 'ended'
}

/** A share link from GET /api/admin/share-links (never includes the token). */
export interface AdminShareLink {
  id: string
  user_id: string
  user_name: string
  user_email: string
  family_id: string | null
  family_name: string | null
  label: string
  created_at: string
  expires_at: string
  revoked_at: string | null
  status: 'active' | 'expired' | 'revoked'
}

export interface HistoryTrailPoint {
  lat: number
  lon: number
  ts: string
  motion_state?: string
  speed_mps?: number
  battery_pct?: number
}

export type HistoryVisitKind = 'place' | 'stop' | 'transit'

export interface HistoryVisit {
  arrived_at: string
  departed_at: string
  lat: number
  lon: number
  place_id?: string | null
  place_name: string
  place_type?: string
  kind: HistoryVisitKind
}

/** Effective Twilio SMS settings from GET /api/admin/settings/sms. */
export interface SmsSettings {
  configured: boolean
  account_sid: string
  auth_token_set: boolean
  from: string
  public_base_url: string
  source: 'settings' | 'environment'
}

/** Dawarich sync state from GET /api/admin/settings/dawarich. */
export interface DawarichSettings {
  enabled: boolean
  base_url: string
  local_url: string
  api_key_set: boolean
  send_unmapped: boolean
  since: string
  last_sync_at: string | null
  last_error: string
  total_sent: number
  pending: number
}

/** One Orbitly account and its Dawarich mapping. */
export interface DawarichUser {
  user_id: string
  name: string
  email: string
  mapped: boolean
  label: string
  enabled: boolean
  api_key_set: boolean
  since: string | null
  last_error: string
  total_sent: number
}

/** One live DNS or HTTPS check for the admin domain status card. */
export interface DomainCheck {
  /** unverified: the check could not confirm it, which is not a failure. */
  status: 'ok' | 'fail' | 'skipped' | 'unverified'
  detail?: string
  addresses?: string[]
}

/** Read-only mirror of how the server is addressed, from GET /api/admin/domain/status. */
export interface DomainStatus {
  site_address: string
  hostname?: string
  custom_domain: boolean
  public_base_url: string
  /** The server's own listener answers: the authoritative "is it up". */
  local?: DomainCheck
  /** HTTPS for the domain through the built-in proxy on this machine. */
  proxy?: DomainCheck
  dns?: DomainCheck
  /** The public URL opened from the server itself: a hint only. */
  https?: DomainCheck
}

export interface ApkReleaseInfo {
  tag_name: string
  name?: string
  body?: string
  html_url?: string
  published_at?: string
  asset_name: string
  asset_size: number
}

export interface ApkStatus {
  status: 'idle' | 'building' | 'success' | 'failed'
  started_at?: string
  finished_at?: string
  artifact_path?: string
  last_error?: string
  release?: ApkReleaseInfo
  release_error?: string
}

/** A saved place as returned by GET /family/places (snake_case backend shape). */
export interface FamilyPlace {
  id: string
  family_id: string
  name: string
  type: string
  lat: number
  lon: number
  radius_meters?: number | null
  address: string
  created_at: string
  /** Circle the place is shared with; null/absent = whole group. */
  circle_id?: string | null
  circle_name?: string | null
}

export interface MemberHistory {
  user_id: string
  from: string
  to: string
  trail: HistoryTrailPoint[]
  visits: HistoryVisit[]
}

/** Discriminated result for the API client. */
export type ApiResult<T> =
  | { ok: true; value: T }
  | { ok: false; status: number; message: string }


/** A place from GET /api/admin/places (any family). */
export interface AdminPlace extends FamilyPlace {
  family_name: string
}

export interface AuditEntry {
  id: number
  user_id: string | null
  user_name: string
  user_email: string
  family_id: string | null
  family_name: string
  action: string
  detail: string
  ip_address: string
  created_at: string
}

export interface AuditPage {
  entries: AuditEntry[]
  next_before_id: number | null
}

/** One active sign-in (refresh-token family). */
export interface AdminSession {
  id: string
  user_id: string
  user_name: string
  user_email: string
  user_agent: string
  created_at: string
  last_used_at: string
  expires_at: string
  current?: boolean
}

export type ActivityKind =
  | 'arrival'
  | 'departure'
  | 'sos'
  | 'help'
  | 'check_in'
  | 'crash'
  | 'bubble_created'
  | 'bubble_entered'
  | 'bubble_left'

export interface ActivityEvent {
  kind: ActivityKind
  at: string
  user_id: string
  user_name: string
  family_id: string | null
  family_name: string
  detail: string
  status: string
  lat?: number
  lon?: number
}

export interface ActivityPage {
  events: ActivityEvent[]
  next_before: string | null
}

// ---- Bubbles (platform admin, read-only) ----

export interface AdminBubbleMember {
  id: string
  name: string
  role: string
}

export interface AdminBubble {
  id: string
  circle_id: string
  circle_name: string
  creator_id: string
  creator_name: string
  subject_id: string
  subject_name: string
  radius_m: number
  notify_reenter: boolean
  inside: boolean
  created_at: string
  expires_at: string
  members: AdminBubbleMember[]
}

/** A member of a circle from GET /api/admin/circles/{id}/members (no coordinates). */
export interface AdminCircleMember {
  user_id: string
  name: string
  email: string
  role: 'admin' | 'member'
  sharing_enabled: boolean
  joined_at: string
}

/** GET /api/admin/health. */
export interface AdminHealth {
  release_version: string
  migration: { version: number; dirty: boolean }
  database_bytes: number
  backup: {
    last_at: string | null
    size_bytes: number | null
    age_hours: number | null
    status: 'ok' | 'stale' | 'missing'
    stale_after_hours: number
    destination?: string
    encrypted?: boolean
  }
  recent_errors: { time: string; level: string; message: string }[]
  warnings: string[]
}

export interface AdminAlertDelivery {
  recipient: string
  channel: string
  state: 'queued' | 'sent' | 'delivered' | 'failed' | 'acknowledged'
  error?: string
  sent_at: string | null
  delivered_at: string | null
  acknowledged_at: string | null
}

/** An alert from GET /api/admin/alerts. Never carries coordinates or the note. */
export interface AdminAlert {
  id: string
  type: string
  status: 'active' | 'resolved'
  sender_id: string
  sender_name: string
  family_name: string
  has_location: boolean
  created_at: string
  resolved_at: string | null
  deliveries: AdminAlertDelivery[]
}

export interface AdminAlertPage {
  alerts: AdminAlert[]
  next_before: string
}

export interface MapStyleSettings {
  /** The admin-set style URL ("" when none is set). */
  map_style_url: string
  /** The MAP_STYLE_URL environment value. */
  env_default: string
  /** What /config serves right now ("" = built-in OpenFreeMap). */
  effective: string
}

// ---- Fleet health (platform admin) ----

/** One phone as reported by GET /api/admin/fleet. No coordinates, no credentials. */
export interface FleetDevice {
  id: string
  platform: string
  name: string
  app_version: string
  os_version: string
  last_seen: string | null
  push_registered: boolean
  push_transport: string
  direct_seen_at: string | null
  last_push_ok_at: string | null
  last_push_fail_at: string | null
  battery_opt: 'unrestricted' | 'optimized' | 'restricted' | 'unknown'
  outbox_pending: number | null
  loc_permission: 'always' | 'while_in_use' | 'denied' | 'unknown'
  notif_permission: 'granted' | 'denied' | 'unknown'
  bg_service: boolean | null
  diag_reported_at: string | null
  client_version?: string
}

export interface FleetMember {
  user_id: string
  name: string
  email: string
  last_report_at: string | null
  last_ws_at: string | null
  in_private_circle: boolean
  last_activity_at?: string | null
  last_private_update_at?: string | null
  devices: FleetDevice[]
}

export interface FleetResponse {
  server_time: string
  members: FleetMember[]
  hidden_devices?: number
}

// ---- Backups card (platform admin) ----

export interface BackupRun {
  at: string
  status: 'success' | 'failed'
  destination: 'local' | 's3' | string
  encrypted: boolean
  size_bytes: number
  duration_ms: number | null
  object_key: string | null
  error: string | null
  trigger: 'schedule' | 'manual' | 'script' | string
}

export interface BackupRequest {
  id: number
  kind: 'backup' | 'test_s3'
  status: 'pending' | 'running' | 'done' | 'failed'
  message: string | null
  requested_at: string
  finished_at: string | null
}

/** Non-secret configuration summary published by the backup service. */
export interface BackupConfigSummary {
  destinations: { kind: 'local' | 's3'; target: string }[]
  encryption: 'age-x25519' | 'age-scrypt' | 'none'
  schedule: string
  timezone: string
  retention: { daily: number; weekly: number; monthly: number; dry_run: boolean }
}

/** GET /api/admin/backups. Never carries credentials or keys. */
export interface AdminBackups {
  agent: {
    running: boolean
    heartbeat_at: string
    started_at: string
    version: string
    next_run_at: string | null
    config: Partial<BackupConfigSummary>
  } | null
  stale_after_hours: number
  last_success: BackupRun | null
  last_failure: BackupRun | null
  /** Per destination, the latest run when it failed. */
  failing: BackupRun[]
  recent: BackupRun[]
  request: BackupRequest | null
}

/** Non-secret, UI-editable backup settings (GET/PUT /api/admin/backups/settings). */
export interface BackupSettingsValues {
  s3_enabled: boolean
  endpoint: string
  region: string
  bucket: string
  prefix: string
  path_style: boolean
  storage_class: string
  insecure: boolean
  allow_private: boolean
  local_enabled: boolean
  age_recipients: string[]
  schedule: string
  timezone: string
  keep_daily: number
  keep_weekly: number
  keep_monthly: number
  stale_hours: number
}

export interface BackupSettingsResponse {
  values: BackupSettingsValues
  /** Field name -> where the effective value comes from. */
  sources: Record<string, 'env' | 'ui' | 'default'>
  /** Fields set by the server environment: read-only in the UI. */
  pinned: string[]
  /** Credentials are write-only: only presence and a hint are ever returned. */
  credentials: {
    access_key_set: boolean
    access_key_hint: string
    secret_set: boolean
    source: 'env' | 'ui' | 'none'
    pinned: boolean
    unreadable: boolean
  }
  updated_at: string | null
  agent_reporting: boolean
  settings_error?: string
  key_configured: boolean
}

export interface BackupSettingsSubmit {
  settings: BackupSettingsValues
  access_key_id?: string
  secret_access_key?: string
  clear_credentials?: boolean
}

/** GET /api/admin/compat: which app versions are in use and the support window. */
export type AppCompatStatus = 'ok' | 'recommended' | 'required' | 'unknown'

export interface AdminCompatVersion {
  app_version: string
  platform: string
  users: number
  last_seen: string
  status: AppCompatStatus
}

export interface AdminCompatUser {
  user_id: string
  name: string
  email: string
  app_version: string
  platform: string
  last_seen: string
  status?: AppCompatStatus
  experience?: string
  missing_features?: string[]
  update_message?: string
}

export interface AdminCompat {
  policy: {
    min_supported_version: string
    latest_version: string
    window: string[]
    window_size: number
    source: 'window' | 'env' | 'admin'
    env_min_supported: string
    override: string
    enforce_writes: boolean
  }
  versions: AdminCompatVersion[]
  outside_window: AdminCompatUser[]
  /** Every person's newest app version per platform, oldest first. */
  people?: AdminCompatUser[]
  server?: { version: string; release: string; features: Record<string, string> }
  /** What a person in each status experiences, in plain words. */
  experience?: Record<AppCompatStatus, string>
  users_total: number
  users_with_version: number
}

// ---- Builds page and System checklist (admin) ----

export type BuildAssetKind =
  | 'android_apk'
  | 'android_aab'
  | 'wear_apk'
  | 'ios_ipa'
  | 'sbom'
  | 'checksums'
  | 'other'

export interface BuildAsset {
  name: string
  kind: BuildAssetKind
  abi?: string
  version?: string
  size: number
  sha256?: string
  download_url?: string
  updated_at?: string
}

export interface BuildRelease {
  tag_name: string
  name?: string
  html_url?: string
  published_at?: string
  prerelease?: boolean
  assets: BuildAsset[]
}

export interface AdminBuilds {
  configured: boolean
  repo?: string
  releases: BuildRelease[]
  fetched_at?: string
  stale?: boolean
  error?: string
  public_apk: string
  public_ipa: string
}

export type CheckStatus = 'ok' | 'warn' | 'fail' | 'info'

export interface SystemCheck {
  id: string
  group: string
  title: string
  status: CheckStatus
  summary: string
  hint?: string
  link?: string
  link_label?: string
}

export interface SystemChecks {
  generated_at: string
  checks: SystemCheck[]
  counts: Record<CheckStatus, number>
  errors_24h: { errors: number; warnings: number }
  ws_clients: number
}
