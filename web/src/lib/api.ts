// API client — a small fetch wrapper that injects the Bearer token, handles
// 401 with a single refresh attempt, and normalizes errors into ApiResult.

import { clearTokens, getAccessToken, getRefreshToken, setTokens } from './auth'
import type {
  AdminInvite,
  AdminMember,
  AdminUser,
  ApkStatus,
  ApiResult,
  Family,
  FamilyPlace,
  InviteCode,
  LoginResponse,
  Me,
  Member,
  MemberHistory,
  MyFamily,
  Profile,
  Role,
  SmsSettings,
  DomainStatus,
} from './types'

const API_BASE = '/api'
const AUTH_BASE = '/auth'

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
    this.name = 'ApiError'
  }
}

/** Special status meaning "auth required and refresh failed" — handled upstream. */
export const REDIRECT_TO_LOGIN = 'REDIRECT_TO_LOGIN'
export class RedirectToLogin extends Error {
  constructor() {
    super(REDIRECT_TO_LOGIN)
    this.name = 'RedirectToLogin'
  }
}

async function refreshTokens(): Promise<boolean> {
  const refreshToken = getRefreshToken()
  if (!refreshToken) return false
  try {
    const res = await fetch(`${AUTH_BASE}/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refreshToken }),
    })
    if (!res.ok) return false
    const tokens = (await res.json()) as LoginResponse
    setTokens(tokens)
    return true
  } catch {
    return false
  }
}

// Paths that already match the Go server (no `/api` prefix). `/family` is
// the same surface the mobile apps use; prepending `/api` 404s and the web
// panel then thinks the signed-in user has no circle.
function isRootApiPath(path: string): boolean {
  return (
    path.startsWith('/api') ||
    path.startsWith('/auth') ||
    path.startsWith('/me') ||
    path.startsWith('/family') ||
    path.startsWith('/ws') ||
    path.startsWith('/devices') ||
    path.startsWith('/locations') ||
    path.startsWith('/alerts') ||
    path.startsWith('/config') ||
    path.startsWith('/healthz')
  )
}

interface RequestOptions {
  method?: string
  /** A value serialized as JSON. */
  body?: unknown
  /** A body that must be passed to fetch unchanged, such as a File or Blob. */
  rawBody?: BodyInit
  /** Explicit content type for a raw body. */
  contentType?: string
  /** Set to true to skip the auth header (used by login itself). */
  noAuth?: boolean
  /** Expect a binary response instead of JSON. */
  binary?: boolean
  /** Expect a plain-text response instead of JSON. */
  text?: boolean
  /** Override the default Accept header. */
  accept?: string
}

async function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {
    Accept: opts.accept ?? (opts.binary ? '*/*' : 'application/json'),
  }
  if (opts.body !== undefined && opts.rawBody !== undefined) {
    throw new Error('Use either body or rawBody, not both')
  }
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json'
  } else if (opts.rawBody !== undefined && opts.contentType) {
    headers['Content-Type'] = opts.contentType
  }
  if (!opts.noAuth) {
    const token = getAccessToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }

  const requestBody =
    opts.rawBody !== undefined
      ? opts.rawBody
      : opts.body !== undefined
        ? JSON.stringify(opts.body)
        : undefined

  const doFetch = (): Promise<Response> =>
    fetch(path.startsWith('http') ? path : `${isRootApiPath(path) ? '' : API_BASE}${path}`, {
      method: opts.method ?? 'GET',
      headers,
      body: requestBody,
    })

  let res = await doFetch()

  // 401 — try one refresh, then replay once.
  if (res.status === 401 && !opts.noAuth) {
    const refreshed = await refreshTokens()
    if (refreshed) {
      const token = getAccessToken()
      if (token) headers.Authorization = `Bearer ${token}`
      res = await doFetch()
    } else {
      clearTokens()
      throw new RedirectToLogin()
    }
  }

  if (!res.ok) {
    let message = res.statusText || 'Request failed'
    try {
      const body = await res.json()
      if (body && typeof body === 'object' && 'message' in body) {
        message = String((body as { message: unknown }).message)
      } else if (body && typeof body === 'object' && 'error' in body) {
        message = String((body as { error: unknown }).error)
      }
    } catch {
      // non-JSON error body — keep statusText
    }
    throw new ApiError(res.status, message)
  }

  if (res.status === 204) return undefined as unknown as T
  if (opts.binary) {
    // Caller wants the raw blob.
    return (await res.blob()) as unknown as T
  }
  if (opts.text) {
    // Caller wants plain text (e.g. the updater log tail).
    return (await res.text()) as unknown as T
  }
  return (await res.json()) as T
}

/** Wrap a call so a thrown ApiError becomes a structured ApiResult. */
export async function result<T>(p: Promise<T>): Promise<ApiResult<T>> {
  try {
    const value = await p
    return { ok: true, value }
  } catch (e) {
    if (e instanceof ApiError) {
      return { ok: false, status: e.status, message: e.message }
    }
    // Network / unexpected error.
    return { ok: false, status: 0, message: e instanceof Error ? e.message : 'Network error' }
  }
}

// ---- Auth ----

export async function login(email: string, password: string): Promise<LoginResponse> {
  return request<LoginResponse>('/auth/login', {
    method: 'POST',
    noAuth: true,
    body: { email, password },
  })
}

// ---- Profile ----

export function getProfile(): Promise<Profile> {
  return request<Profile>('/api/profile')
}

/** Returns the current user's avatar image bytes. */
export function getProfileAvatar(): Promise<Blob> {
  return request<Blob>('/api/profile/avatar', { binary: true, accept: 'image/jpeg, image/png, image/*;q=0.8, */*;q=0.1' })
}

/** Upload a JPEG or PNG avatar as the raw request body. */
export function uploadProfileAvatar(file: File): Promise<void> {
  return request<void>('/api/profile/avatar', {
    method: 'PUT',
    rawBody: file,
    contentType: file.type,
  })
}

/** Remove the current user's avatar. */
export function deleteProfileAvatar(): Promise<void> {
  return request<void>('/api/profile/avatar', { method: 'DELETE' })
}

/** Update the signed-in user's display name. */
export function updateProfile(name: string): Promise<{ name: string }> {
  return request<{ name: string }>('/me', { method: 'PATCH', body: { name } })
}

/** Change the signed-in user's password. Stays signed in on success. */
export function changePassword(currentPassword: string, newPassword: string): Promise<void> {
  return request<void>('/me/password', {
    method: 'PATCH',
    body: { current_password: currentPassword, new_password: newPassword },
  })
}

// ---- My account (/me) ----

/** Returns the signed-in account, including role and platform_admin flags. */
export function whoAmI(): Promise<Me> {
  return request<Me>('/me')
}

// ---- My circle — the family-scoped endpoints the mobile apps use ----
// Every authenticated user may call these for their own family; the server
// enforces family-admin rules per action. The web panel uses them so regular
// users get app parity instead of a wall of 403s.

/** Returns the caller's own family plus the caller's role within it. 404 when familyless. */
export function getMyFamily(): Promise<MyFamily> {
  return request<MyFamily>('/family')
}

/** Returns the caller's family members with their last-known location. */
export function listMyFamilyMembers(): Promise<Member[]> {
  return request<Member[]>('/family/members')
}

/** Returns a member of the caller's own family: avatar bytes or 404. */
export function getFamilyMemberAvatar(memberId: string): Promise<Blob> {
  return request<Blob>(`/family/members/${encodeURIComponent(memberId)}/avatar`, {
    binary: true,
    accept: 'image/jpeg, image/png, image/*;q=0.8, */*;q=0.1',
  })
}

/** Returns one member's day trail + visits within the caller's own family. */
export function getFamilyMemberHistory(
  memberId: string,
  from: string,
  to: string,
): Promise<MemberHistory> {
  const q = new URLSearchParams({ from, to })
  return request<MemberHistory>(
    `/family/members/${encodeURIComponent(memberId)}/history?${q.toString()}`,
  )
}

/** Returns saved places shared with the caller's family. 404 when familyless. */
export function listMyPlaces(): Promise<FamilyPlace[]> {
  return request<FamilyPlace[]>('/family/places')
}

/** Renames the caller's family (family admin only). */
export function renameMyFamily(name: string): Promise<{ status: string; name?: string }> {
  return request<{ status: string; name?: string }>('/family', { method: 'PATCH', body: { name } })
}

/** Creates an invite code for the caller's family (family admin only). */
export function createFamilyInviteCode(
  opts?: { role?: Role; max_uses?: number; expires_in_hours?: number },
): Promise<InviteCode> {
  return request<InviteCode>('/family/invites', { method: 'POST', body: opts ?? {} })
}

/** Creates a family and makes the caller its admin. App-parity (not the admin API). */
export function createMyFamily(name: string): Promise<Family> {
  return request<Family>('/families', { method: 'POST', body: { name } })
}

/** Joins a family by consuming an invite code. Only allowed while familyless. */
export function joinFamilyByCode(code: string): Promise<{ status: string }> {
  return request<{ status: string }>('/family/join', { method: 'POST', body: { code } })
}

/** Leaves the caller's family. Blocked for the last admin. */
export function leaveMyFamily(): Promise<{ status: string }> {
  return request<{ status: string }>('/family/leave', { method: 'POST' })
}

/** Changes a member's role inside the caller's family (family admin only). */
export function updateFamilyMemberRole(memberId: string, role: Role): Promise<{ status: string }> {
  return request<{ status: string }>(`/family/members/${encodeURIComponent(memberId)}/role`, {
    method: 'PATCH',
    body: { role },
  })
}

// ---- Admin endpoints ----

export function listFamilies(): Promise<Family[]> {
  return request<Family[]>('/api/admin/families')
}

export function listFamilyMembers(familyId: string): Promise<Member[]> {
  return request<Member[]>(`/api/admin/families/${encodeURIComponent(familyId)}/members`)
}

export function listAllMembers(): Promise<AdminMember[]> {
  return request<AdminMember[]>('/api/admin/members')
}

export function getMemberHistory(memberId: string, from: string, to: string): Promise<MemberHistory> {
  const q = new URLSearchParams({ from, to })
  return request<MemberHistory>(
    `/api/admin/members/${encodeURIComponent(memberId)}/history?${q.toString()}`,
  )
}

/** Returns a member's avatar bytes through the authenticated admin endpoint. */
export function getAdminMemberAvatar(memberId: string): Promise<Blob> {
  return request<Blob>(`/api/admin/members/${encodeURIComponent(memberId)}/avatar`, {
    binary: true,
    accept: 'image/jpeg, image/png, image/*;q=0.8, */*;q=0.1',
  })
}

export function createFamily(name: string): Promise<Family> {
  return request<Family>('/api/admin/families', { method: 'POST', body: { name } })
}

export function renameFamily(familyId: string, name: string): Promise<{ status: string }> {
  return request<{ status: string }>(`/api/admin/families/${encodeURIComponent(familyId)}`, {
    method: 'PATCH',
    body: { name },
  })
}

export function deleteFamily(familyId: string): Promise<{ status: string }> {
  return request<{ status: string }>(`/api/admin/families/${encodeURIComponent(familyId)}`, {
    method: 'DELETE',
  })
}

export function moveMember(
  memberId: string,
  familyId: string,
  role?: Role,
): Promise<{ status: string }> {
  return request<{ status: string }>(`/api/admin/members/${encodeURIComponent(memberId)}/family`, {
    method: 'PATCH',
    body: { family_id: familyId, role },
  })
}

export function listUsers(): Promise<AdminUser[]> {
  return request<AdminUser[]>('/api/admin/users')
}

export function createUser(input: {
  email: string
  password: string
  name: string
  role: Role
  family_id?: string
}): Promise<AdminUser> {
  return request<AdminUser>('/api/admin/users', { method: 'POST', body: input })
}

export function updateUser(
  userId: string,
  input: { name?: string; email?: string; phone?: string },
): Promise<AdminUser> {
  return request<AdminUser>(`/api/admin/users/${encodeURIComponent(userId)}`, {
    method: 'PATCH',
    body: input,
  })
}

export function assignUser(userId: string, familyId: string | null): Promise<AdminUser> {
  return request<AdminUser>(`/api/admin/users/${encodeURIComponent(userId)}/family`, {
    method: 'PATCH',
    body: { family_id: familyId },
  })
}

export function updateUserRole(userId: string, role: Role): Promise<AdminUser> {
  return request<AdminUser>(`/api/admin/users/${encodeURIComponent(userId)}/role`, {
    method: 'PATCH',
    body: { role },
  })
}

export function resetUserPassword(userId: string, password: string): Promise<void> {
  return request<void>(`/api/admin/users/${encodeURIComponent(userId)}/password`, {
    method: 'PATCH',
    body: { password },
  })
}

export function listInvites(): Promise<AdminInvite[]> {
  return request<AdminInvite[]>('/api/admin/invites')
}

export function createInvite(
  familyId: string,
  opts?: { role?: Role; max_uses?: number; expires_in_hours?: number },
): Promise<InviteCode> {
  return request<InviteCode>('/api/admin/invites', {
    method: 'POST',
    body: { family_id: familyId, ...opts },
  })
}

/** Returns a blob; caller should trigger a download. */
export function downloadApk(): Promise<Blob> {
  return request<Blob>('/api/admin/apk', { binary: true })
}

/** Returns metadata for the latest published Android release. */
export function getApkStatus(): Promise<ApkStatus> {
  return request<ApkStatus>('/api/admin/apk/status')
}

export function getSmsSettings(): Promise<SmsSettings> {
  return request<SmsSettings>('/api/admin/settings/sms')
}

export function updateSmsSettings(input: {
  account_sid: string
  auth_token: string
  from: string
  public_base_url: string
}): Promise<SmsSettings> {
  return request<SmsSettings>('/api/admin/settings/sms', { method: 'PUT', body: input })
}

export function clearSmsSettings(): Promise<SmsSettings> {
  return request<SmsSettings>('/api/admin/settings/sms', { method: 'DELETE' })
}

// ---- Domain status (platform admin) ----

export function getDomainStatus(): Promise<DomainStatus> {
  return request<DomainStatus>('/api/admin/domain/status')
}

// ---- Server version (platform admin, read-only) ----

/** Running server version. Upgrades are done on the host with scripts/upgrade.sh. */
export function getServerVersion(): Promise<{ version: string }> {
  return request<{ version: string }>('/api/admin/version')
}
