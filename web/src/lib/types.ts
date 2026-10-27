// Shared API types for the OpenFamily admin panel.
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
}

export interface HistoryTrailPoint {
  lat: number
  lon: number
  ts: string
  motion_state?: string
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

/** One OpenFamily account and its Dawarich mapping. */
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
  status: 'ok' | 'fail' | 'skipped'
  detail?: string
  addresses?: string[]
}

/** Read-only mirror of how the server is addressed, from GET /api/admin/domain/status. */
export interface DomainStatus {
  site_address: string
  hostname?: string
  custom_domain: boolean
  public_base_url: string
  dns?: DomainCheck
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
