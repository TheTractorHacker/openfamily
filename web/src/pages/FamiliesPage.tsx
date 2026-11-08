// Families page.
//
// Platform admins get the server-wide view: every family with member counts,
// per-member "move to family" repair, invite-code generation, and
// rename/delete/create actions.
//
// Regular users get app parity instead: exactly what the mobile apps allow on
// their own circle — create a circle or join by invite code, see members and
// their locations, generate an invite code / rename / change roles when they
// are the family's admin, and leave the circle. Server-wide actions (delete,
// move between families) stay admin-only.

import React from 'react'
import {
  createFamily,
  createMyFamily,
  createInvite,
  createFamilyInviteCode,
  deleteFamily,
  getAdminMemberAvatar,
  getFamilyMemberAvatar,
  getMyFamily,
  joinFamilyByCode,
  leaveMyFamily,
  listFamilyMembers,
  listFamilies,
  listInvites,
  listMyFamilyMembers,
  moveMember,
  renameFamily,
  renameMyFamily,
  updateFamilyMemberRole,
} from '../lib/api'
import { refreshMe, useMe } from '../lib/me'
import { useAsync, isAccessDenied } from '../lib/useAsync'
import {
  AccessDenied,
  Badge,
  Button,
  Card,
  CopyButton,
  EmptyState,
  ErrorState,
  Spinner,
} from '../components/primitives'
import {
  formatAccuracy,
  formatBattery,
  formatDate,
  formatRelativeTime,
  formatSpeed,
  initialsOf,
} from '../lib/format'
import { getAccessToken } from '../lib/auth'
import type { AdminInvite, Family, Member, MyFamily, Role } from '../lib/types'
import { useMemberAvatarUrls } from '../lib/useMemberAvatarUrls'
import './pages.css'
import './FamiliesPage.css'

interface AvatarUpdate {
  userId: string
  hasAvatar: boolean
  avatarUpdatedAt: string | null
  avatarVersion: number
}

function avatarVersion(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
    ? value
    : null
}

function memberAvatarVersion(member: Member): number {
  return avatarVersion(member.avatar_version) ?? 0
}

function adminWebSocketUrl(path: string): string {
  const url = new URL(path, window.location.origin)
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  return url.toString()
}

/**
 * One live stream for the whole Families page. Family rows consume the
 * resulting metadata rather than creating a socket per expanded table.
 * Platform admins listen on /api/admin/ws (all families); regular users listen
 * on /ws/stream — their own circle, exactly like the apps.
 */
function useAvatarUpdates(streamPath: string): ReadonlyMap<string, AvatarUpdate> {
  const token = getAccessToken()
  const [updates, setUpdates] = React.useState<ReadonlyMap<string, AvatarUpdate>>(
    () => new Map(),
  )

  React.useEffect(() => {
    // Do not carry avatar metadata from a prior authenticated session into a
    // new one. The member API remains authoritative after a login change.
    setUpdates(new Map())
    if (!token || typeof window === 'undefined') return

    let stopped = false
    let socket: WebSocket | null = null
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null
    let retries = 0

    const scheduleReconnect = () => {
      if (stopped || reconnectTimer != null) return
      const delay = Math.min(1000 * 2 ** retries, 30000)
      retries = Math.min(retries + 1, 5)
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null
        connect()
      }, delay)
    }

    const connect = () => {
      if (stopped) return
      try {
        socket = new WebSocket(adminWebSocketUrl(streamPath), token)
      } catch {
        scheduleReconnect()
        return
      }

      socket.onopen = () => {
        retries = 0
      }
      socket.onmessage = (event) => {
        let frame: Record<string, unknown>
        try {
          const parsed: unknown = JSON.parse(event.data as string)
          if (parsed == null || typeof parsed !== 'object') return
          frame = parsed as Record<string, unknown>
        } catch {
          return
        }
        if (frame.type !== 'avatar' ||
            typeof frame.user_id !== 'string' ||
            frame.user_id.length === 0 ||
            typeof frame.has_avatar !== 'boolean') {
          return
        }
        const version = avatarVersion(frame.avatar_version)
        // An unversioned frame cannot be ordered safely, so never let it
        // displace a snapshot or a newer live update.
        if (version == null) return
        const update: AvatarUpdate = {
          userId: frame.user_id,
          hasAvatar: frame.has_avatar,
          avatarUpdatedAt:
              typeof frame.avatar_updated_at === 'string'
                  ? frame.avatar_updated_at
                  : null,
          avatarVersion: version,
        }
        setUpdates((previous) => {
          const known = previous.get(update.userId)
          if (known != null && update.avatarVersion <= known.avatarVersion) {
            return previous
          }
          const next = new Map(previous)
          next.set(update.userId, update)
          return next
        })
      }
      socket.onclose = scheduleReconnect
      socket.onerror = () => socket?.close()
    }

    connect()
    return () => {
      stopped = true
      if (reconnectTimer != null) clearTimeout(reconnectTimer)
      socket?.close()
    }
  }, [token, streamPath])

  return updates
}

export function FamiliesPage() {
  const { isPlatformAdmin } = useMe()
  // Regular users manage their own circle with app permissions; the server-wide
  // list stays platform-admin only.
  if (!isPlatformAdmin) return <MyCirclePage />
  return <AllFamiliesPage />
}

/** The server-wide family management view — platform admins only. */
function AllFamiliesPage() {
  const families = useAsync(listFamilies, [])
  const avatarUpdates = useAvatarUpdates('/api/admin/ws')
  const [creating, setCreating] = React.useState(false)
  const [newName, setNewName] = React.useState('')
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  const submitNew = async () => {
    const name = newName.trim()
    if (!name) return
    setBusy(true)
    setError(null)
    try {
      await createFamily(name)
      setNewName('')
      setCreating(false)
      await families.refetch()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to create group')
    } finally {
      setBusy(false)
    }
  }

  if (families.loading) return <FamiliesSkeleton />
  if (isAccessDenied(families.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  if (families.error) {
    return (
      <div className="wb-page">
        <ErrorState
          title="Couldn’t load groups"
          description={families.error.message}
          onRetry={families.refetch}
        />
      </div>
    )
  }

  const list = families.data ?? []

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Groups</h1>
          <p className="wb-page-subtitle">
            {list.length} {list.length === 1 ? 'group' : 'groups'} on this server.
          </p>
        </div>
        <div className="wb-row">
          <Button variant="secondary" size="sm" onClick={families.refetch}>
            Refresh
          </Button>
          <Button size="sm" onClick={() => setCreating((c) => !c)}>
            New group
          </Button>
        </div>
      </div>

      {creating && (
        <Card className="wb-new-family">
          <div className="wb-row">
            <input
              className="wb-input"
              placeholder="Group name"
              value={newName}
              autoFocus
              onChange={(e) => setNewName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') submitNew()
              }}
            />
            <Button size="sm" loading={busy} onClick={submitNew}>
              Create
            </Button>
            <Button variant="ghost" size="sm" onClick={() => setCreating(false)}>
              Cancel
            </Button>
          </div>
          {error && <p className="wb-error-text">{error}</p>}
        </Card>
      )}

      {list.length === 0 ? (
        <Card>
          <EmptyState
            title="No groups yet"
            description="Create a group, then generate an invite code so people can join it."
            icon={<FamiliesIcon />}
            action={
              <Button size="sm" onClick={() => setCreating(true)}>
                New group
              </Button>
            }
          />
        </Card>
      ) : (
        <div className="wb-groups-list">
          {list.map((f) => (
            <FamilyRow
              key={f.id}
              family={f}
              families={list}
              avatarUpdates={avatarUpdates}
              onChanged={families.refetch}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function FamilyRow({
  family,
  families,
  avatarUpdates,
  onChanged,
}: {
  family: Family
  families: Family[]
  avatarUpdates: ReadonlyMap<string, AvatarUpdate>
  onChanged: () => void
}) {
  const [open, setOpen] = React.useState(false)
  const members = useAsync(
    () => (open ? listFamilyMembers(family.id) : Promise.resolve([] as Member[])),
    [family.id, open],
  )
  const invites = useAsync(
    () => (open ? listInvites() : Promise.resolve([] as AdminInvite[])),
    [open],
  )

  const [renaming, setRenaming] = React.useState(false)
  const [renameValue, setRenameValue] = React.useState(family.name)
  const [inviteCode, setInviteCode] = React.useState<string | null>(null)
  const [actionError, setActionError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)

  // A REST member row is still the source of all non-avatar details. Overlay
  // only a strictly newer avatar event so an old event cannot undo a later
  // snapshot (or a later photo removal).
  const displayedMembers = React.useMemo(
    () =>
      (members.data ?? []).map((member) => {
        const update = avatarUpdates.get(member.id)
        if (update == null || update.avatarVersion <= memberAvatarVersion(member)) {
          return member
        }
        return {
          ...member,
          has_avatar: update.hasAvatar,
          avatar_updated_at: update.hasAvatar ? update.avatarUpdatedAt : null,
          avatar_version: update.avatarVersion,
        }
      }),
    [avatarUpdates, members.data],
  )

  const memberAvatarSources = React.useMemo(
    () =>
      displayedMembers.map((member) => ({
        id: member.id,
        hasAvatar: member.has_avatar,
        avatarUpdatedAt: member.avatar_updated_at,
        avatarVersion: member.avatar_version,
      })),
    [displayedMembers],
  )
  const memberAvatarUrls = useMemberAvatarUrls(memberAvatarSources, getAdminMemberAvatar, {
    enabled: open,
  })

  const familyInvites = (invites.data ?? []).filter((i) => i.family_id === family.id)
  const otherFamilies = families.filter((f) => f.id !== family.id)

  const doRename = async () => {
    const name = renameValue.trim()
    if (!name || name === family.name) {
      setRenaming(false)
      return
    }
    setBusy(true)
    setActionError(null)
    try {
      await renameFamily(family.id, name)
      setRenaming(false)
      onChanged()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Failed to rename')
    } finally {
      setBusy(false)
    }
  }

  const doDelete = async () => {
    if (!window.confirm(`Delete group “${family.name}”? Its members will become unassigned.`)) return
    setBusy(true)
    setActionError(null)
    try {
      await deleteFamily(family.id)
      onChanged()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Failed to delete')
    } finally {
      setBusy(false)
    }
  }

  const doInvite = async () => {
    setBusy(true)
    setActionError(null)
    try {
      const inv = await createInvite(family.id)
      setInviteCode(inv.code)
      invites.refetch()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Failed to create invite')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card padded={false} className="wb-group-card">
      <button
        type="button"
        className="wb-group-head"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="wb-group-avatar" aria-hidden="true">
          {initialsOf(family.name)}
        </span>
        <span className="wb-group-meta">
          <span className="wb-group-name">{family.name}</span>
          <span className="wb-group-sub">Created {formatDate(family.created_at)}</span>
        </span>
        <span className="wb-group-count">
          <Badge tone="purple">
            {family.member_count} {family.member_count === 1 ? 'member' : 'members'}
          </Badge>
        </span>
        <span className={`wb-group-chevron ${open ? 'is-open' : ''}`} aria-hidden="true">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <path d="m6 9 6 6 6-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
      </button>

      {open && (
        <div className="wb-group-body">
          <div className="wb-group-actions">
            <Button size="sm" variant="secondary" loading={busy} onClick={doInvite}>
              Invite code
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setRenaming((r) => !r)}>
              Rename
            </Button>
            <Button size="sm" variant="danger" onClick={doDelete}>
              Delete
            </Button>
          </div>

          {actionError && <p className="wb-error-text wb-group-action-error">{actionError}</p>}

          {renaming && (
            <div className="wb-group-rename">
              <input
                className="wb-input"
                value={renameValue}
                autoFocus
                onChange={(e) => setRenameValue(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') doRename()
                  if (e.key === 'Escape') setRenaming(false)
                }}
              />
              <Button size="sm" loading={busy} onClick={doRename}>
                Save
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setRenaming(false)}>
                Cancel
              </Button>
            </div>
          )}

          {inviteCode && (
            <div className="wb-invite-banner">
              <span className="wb-invite-label">Invite code</span>
              <span className="wb-invite-code">{inviteCode}</span>
              <CopyButton value={inviteCode} label="Copy invite code" />
              <span className="wb-invite-hint">Share this code; it expires in 7 days.</span>
            </div>
          )}

          {familyInvites.length > 0 && (
            <div className="wb-invite-list">
              <div className="wb-invite-list-title">Active invite codes</div>
              {familyInvites.map((i) => (
                <div key={i.id} className="wb-invite-row">
                  <span className="wb-invite-code">{i.code}</span>
                  <span className="wb-invite-meta">
                    {i.uses}/{i.max_uses} used · {i.role} · expires {formatDate(i.expires_at)}
                  </span>
                  <CopyButton value={i.code} label="Copy invite code" />
                </div>
              ))}
            </div>
          )}

          {members.loading ? (
            <div className="wb-group-body-loading">
              <Spinner size={16} /> Loading members…
            </div>
          ) : members.error ? (
            <ErrorState
              title="Couldn’t load members"
              description={members.error.message}
              onRetry={members.refetch}
            />
          ) : (members.data?.length ?? 0) === 0 ? (
            <EmptyState
              title="No members yet"
              description="Generate an invite code above so someone can join this group."
            />
          ) : (
            <div className="wb-table-wrap">
              <table className="wb-table">
                <thead>
                  <tr>
                    <th>Member</th>
                    <th>Role</th>
                    <th>Last seen</th>
                    <th>Battery</th>
                    <th>Speed</th>
                    <th>Accuracy</th>
                    <th>Move to group</th>
                  </tr>
                </thead>
                <tbody>
                  {displayedMembers.map((m) => (
                    <tr key={m.id}>
                      <td>
                        <div className="wb-member-cell">
                          <span className="wb-member-dot" aria-hidden="true">
                            {memberAvatarUrls[m.id] ? (
                              <img src={memberAvatarUrls[m.id]} alt="" />
                            ) : (
                              initialsOf(m.name)
                            )}
                          </span>
                          <span>
                            <div className="wb-member-name">{m.name}</div>
                            <div className="wb-member-email">{m.email}</div>
                          </span>
                        </div>
                      </td>
                      <td>
                        <RoleBadge role={m.role} />
                      </td>
                      <td className="wb-muted">{formatRelativeTime(m.ts)}</td>
                      <td className="wb-num">
                        <BatteryPct pct={m.battery_pct} />
                      </td>
                      <td className="wb-num">{formatSpeed(m.speed_mps)}</td>
                      <td className="wb-muted wb-num">{formatAccuracy(m.accuracy_meters)}</td>
                      <td>
                        <MoveMember
                          member={m}
                          families={otherFamilies}
                          onMoved={() => {
                            members.refetch()
                            onChanged()
                          }}
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </Card>
  )
}

function MoveMember({
  member,
  families,
  onMoved,
}: {
  member: Member
  families: Family[]
  onMoved: () => void
}) {
  const [target, setTarget] = React.useState('')
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  if (families.length === 0) {
    return <span className="wb-muted">No other groups</span>
  }

  const doMove = async () => {
    if (!target) return
    setBusy(true)
    setError(null)
    try {
      await moveMember(member.id, target)
      setTarget('')
      onMoved()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to move')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="wb-move">
      <select
        className="wb-select wb-move-select"
        value={target}
        onChange={(e) => setTarget(e.target.value)}
        aria-label={`Move ${member.name} to group`}
      >
        <option value="">Choose…</option>
        {families.map((f) => (
          <option key={f.id} value={f.id}>
            {f.name}
          </option>
        ))}
      </select>
      <Button size="sm" variant="secondary" disabled={!target} loading={busy} onClick={doMove}>
        Move
      </Button>
      {error && <span className="wb-error-text">{error}</span>}
    </div>
  )
}

function RoleBadge({ role }: { role: Role }) {
  const tone = role === 'admin' ? 'pink' : role === 'member' ? 'purple' : 'grey'
  const label = role.charAt(0).toUpperCase() + role.slice(1)
  return <Badge tone={tone}>{label}</Badge>
}

function BatteryPct({ pct }: { pct: number | null }) {
  const text = formatBattery(pct)
  if (pct === null) return <span className="wb-muted">{text}</span>
  const tone = pct <= 15 ? 'red' : pct <= 30 ? 'orange' : 'green'
  return <Badge tone={tone} dot>{text}</Badge>
}

function FamiliesSkeleton() {
  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Groups</h1>
          <p className="wb-page-subtitle">Groups using this Orbitly server.</p>
        </div>
      </div>
      <div className="wb-stack">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="wb-skeleton wb-skeleton-row" />
        ))}
      </div>
    </div>
  )
}

function FamiliesIcon() {
  return (
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
      <path
        d="M16 11a3 3 0 1 0-2.6-4.5M8 11a3 3 0 1 1 2.6-4.5M3 20c0-2.8 2-5 4.5-5h9C19 15 21 17.2 21 20"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

// ---- My circle — what a regular (non-platform-admin) user can do ----

/**
 * The signed-in user's own family, with the same capabilities the mobile apps
 * expose for their role: rename / invite / role changes for family admins,
 * view-only membership otherwise, plus leave / join-by-code / create-circle.
 */
function MyCirclePage() {
  const family = useAsync(getMyFamily, [])
  const avatarUpdates = useAvatarUpdates('/ws/stream')
  const [inviteCode, setInviteCode] = React.useState<string | null>(null)

  if (family.loading) return <FamiliesSkeleton />

  // No circle yet: offer exactly what the app's welcome flow offers.
  if (family.error?.status === 404) {
    return (
      <div className="wb-page">
        <PageHeader title="Groups" subtitle="Create a new circle or join one with an invite code." />
        <CreateOrJoinCard
          onDone={() => {
            family.refetch()
            refreshMe()
          }}
        />
      </div>
    )
  }

  if (family.error) {
    return (
      <div className="wb-page">
        <ErrorState title="Couldn’t load your group" description={family.error.message} onRetry={family.refetch} />
      </div>
    )
  }

  const f = family.data as MyFamily
  const isAdmin = f.role === 'admin'

  const doInvite = async () => {
    setInviteCode(null)
    try {
      const inv = await createFamilyInviteCode()
      setInviteCode(inv.code)
    } catch {
      // Surface the server's rule through the member list error path instead;
      // non-admins never see the invite button anyway.
      setInviteCode('')
    }
  }

  return (
    <div className="wb-page">
      <PageHeader
        title={f.name}
        subtitle={`Your circle · you are ${roleLabel(f.role)}. Members share locations with each other.`}
      />

      {isAdmin && (
        <div className="wb-row wb-family-owner-actions">
          <Button size="sm" variant="secondary" onClick={doInvite}>
            Invite code
          </Button>
        </div>
      )}

      {inviteCode === '' ? (
        <p className="wb-error-text">Couldn’t create an invite code. Ask your server administrator if this persists.</p>
      ) : inviteCode ? (
        <div className="wb-invite-banner">
          <span className="wb-invite-label">Invite code</span>
          <span className="wb-invite-code">{inviteCode}</span>
          <CopyButton value={inviteCode} label="Copy invite code" />
          <span className="wb-invite-hint">Share this code so someone can join this circle.</span>
        </div>
      ) : null}

      <MyFamilyMembers
        family={f}
        canManage={isAdmin}
        avatarUpdates={avatarUpdates}
        onChanged={() => {
          // Leaving (or any roster change) also refreshes identity flags.
          family.refetch()
          refreshMe()
        }}
      />
    </div>
  )
}

/** Member roster of the caller's own family, plus the leave action. */
function MyFamilyMembers({
  family,
  canManage,
  avatarUpdates,
  onChanged,
}: {
  family: MyFamily
  canManage: boolean
  avatarUpdates: ReadonlyMap<string, AvatarUpdate>
  /** Called after a change that affects the caller's membership or the family. */
  onChanged: () => void
}) {
  const members = useAsync(listMyFamilyMembers, [])
  const [renameOpen, setRenameOpen] = React.useState(false)
  const [renameValue, setRenameValue] = React.useState(family.name)
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)
  const [rowError, setRowError] = React.useState<Record<string, string>>({})

  const displayedMembers = React.useMemo(
    () =>
      (members.data ?? []).map((member) => {
        const update = avatarUpdates.get(member.id)
        if (update == null || update.avatarVersion <= memberAvatarVersion(member)) {
          return member
        }
        return {
          ...member,
          has_avatar: update.hasAvatar,
          avatar_updated_at: update.hasAvatar ? update.avatarUpdatedAt : null,
          avatar_version: update.avatarVersion,
        }
      }),
    [avatarUpdates, members.data],
  )

  const memberAvatarSources = React.useMemo(
    () =>
      displayedMembers.map((member) => ({
        id: member.id,
        hasAvatar: member.has_avatar,
        avatarUpdatedAt: member.avatar_updated_at,
        avatarVersion: member.avatar_version,
      })),
    [displayedMembers],
  )
  const memberAvatarUrls = useMemberAvatarUrls(memberAvatarSources, getFamilyMemberAvatar, {})

  const adminCount = (members.data ?? []).filter((m) => m.role === 'admin').length
  const isLastAdmin = canManage && adminCount <= 1

  const doRename = async () => {
    const name = renameValue.trim()
    if (!name || name === family.name) {
      setRenameOpen(false)
      return
    }
    setBusy(true)
    setError(null)
    try {
      await renameMyFamily(name)
      setRenameOpen(false)
      members.refetch()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to rename')
    } finally {
      setBusy(false)
    }
  }

  const doLeave = async () => {
    if (!window.confirm('Leave this group? You will stop sharing location with them. You can join another group with an invite code, or create a new one.')) return
    setBusy(true)
    setError(null)
    try {
      await leaveMyFamily()
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not leave the group.')
    } finally {
      setBusy(false)
    }
  }

  const changeRole = async (memberId: string, role: Role) => {
    setRowError((prev) => ({ ...prev, [memberId]: '' }))
    try {
      await updateFamilyMemberRole(memberId, role)
      members.refetch()
    } catch (e) {
      setRowError((prev) => ({
        ...prev,
        [memberId]: e instanceof Error ? e.message : 'Could not change that role.',
      }))
    }
  }

  if (members.loading) {
    return (
      <Card>
        <div className="wb-group-body-loading">
          <Spinner size={16} /> Loading members…
        </div>
      </Card>
    )
  }

  if (members.error) {
    return (
      <Card>
        <ErrorState title="Couldn’t load members" description={members.error.message} onRetry={members.refetch} />
      </Card>
    )
  }

  return (
    <>
      <Card padded={false} className="wb-group-card">
        <div className="wb-group-head is-static">
          <span className="wb-group-avatar" aria-hidden="true">
            {initialsOf(family.name)}
          </span>
          <span className="wb-group-meta">
            <span className="wb-group-name">{family.name}</span>
            <span className="wb-group-sub">Created {formatDate(family.created_at)}</span>
          </span>
          <span className="wb-group-count">
            <Badge tone="purple">
              {displayedMembers.length}{' '}
              {displayedMembers.length === 1 ? 'member' : 'members'}
            </Badge>
          </span>
          {canManage && (
            <Button size="sm" variant="ghost" onClick={() => setRenameOpen((r) => !r)}>
              Rename
            </Button>
          )}
        </div>

        {error && <p className="wb-error-text wb-group-action-error">{error}</p>}

        {renameOpen && (
          <div className="wb-group-rename">
            <input
              className="wb-input"
              value={renameValue}
              autoFocus
              onChange={(e) => setRenameValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') doRename()
                if (e.key === 'Escape') setRenameOpen(false)
              }}
            />
            <Button size="sm" loading={busy} onClick={doRename}>
              Save
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setRenameOpen(false)}>
              Cancel
            </Button>
          </div>
        )}

        <div className="wb-table-wrap">
          <table className="wb-table">
            <thead>
              <tr>
                <th>Member</th>
                <th>Role</th>
                <th>Last seen</th>
                <th>Battery</th>
                {canManage && <th>Change role</th>}
              </tr>
            </thead>
            <tbody>
              {displayedMembers.map((m) => (
                <tr key={m.id}>
                  <td>
                    <div className="wb-member-cell">
                      <span className="wb-member-dot" aria-hidden="true">
                        {memberAvatarUrls[m.id] ? (
                          <img src={memberAvatarUrls[m.id]} alt="" />
                        ) : (
                          initialsOf(m.name)
                        )}
                      </span>
                      <span>
                        <div className="wb-member-name">{m.name}</div>
                        {m.email && <div className="wb-member-email">{m.email}</div>}
                      </span>
                    </div>
                  </td>
                  <td>
                    <RoleBadge role={m.role} />
                  </td>
                  <td className="wb-muted">{formatRelativeTime(m.ts)}</td>
                  <td className="wb-num">
                    <BatteryPct pct={m.battery_pct} />
                  </td>
                  {canManage && (
                    <td>
                      <select
                        className="wb-select wb-move-select"
                        value={m.role}
                        aria-label={`Change ${m.name}'s role`}
                        onChange={(e) => changeRole(m.id, e.target.value as Role)}
                      >
                        <option value="admin">Admin</option>
                        <option value="member">Member</option>
                        <option value="child">Child</option>
                      </select>
                      {rowError[m.id] && <span className="wb-error-text">{rowError[m.id]}</span>}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Card className="wb-leave-card">
        <h3 className="wb-settings-title">Leave this circle</h3>
        <p className="wb-settings-section-help">
          You will stop sharing location with this family. You can join another family with an
          invite code, or create a new one.
        </p>
        {isLastAdmin && (
          <p className="wb-settings-section-help">Promote another admin before you leave.</p>
        )}
        {error && <p className="wb-error-text">{error}</p>}
        <Button variant="danger" loading={busy} disabled={isLastAdmin || busy} onClick={doLeave}>
          Leave family
        </Button>
      </Card>
    </>
  )
}

/** Create-a-circle / join-by-code — the familyless state, mirroring the app. */
function CreateOrJoinCard({ onDone }: { onDone: () => void }) {
  const [name, setName] = React.useState('')
  const [code, setCode] = React.useState('')
  const [busy, setBusy] = React.useState<'create' | 'join' | null>(null)
  const [createError, setCreateError] = React.useState<string | null>(null)
  const [joinError, setJoinError] = React.useState<string | null>(null)

  const doCreate = async () => {
    const trimmed = name.trim()
    if (!trimmed) return
    setBusy('create')
    setCreateError(null)
    try {
      await createMyFamily(trimmed)
      onDone()
    } catch (e) {
      setCreateError(e instanceof Error ? e.message : 'Failed to create group')
    } finally {
      setBusy(null)
    }
  }

  const doJoin = async () => {
    const trimmed = code.trim()
    if (!trimmed) return
    setBusy('join')
    setJoinError(null)
    try {
      await joinFamilyByCode(trimmed)
      onDone()
    } catch (e) {
      setJoinError(e instanceof Error ? e.message : 'That code didn’t work. Check it and try again.')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="wb-settings-grid">
      <Card>
        <h3 className="wb-settings-title">Create a new circle</h3>
        <p className="wb-settings-section-help">
          Start fresh: you become the circle’s admin and can invite people with a code.
        </p>
        <div className="wb-row">
          <input
            className="wb-input"
            placeholder="Group name"
            value={name}
            autoFocus
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') doCreate()
            }}
          />
          <Button size="sm" loading={busy === 'create'} onClick={doCreate}>
            Create
          </Button>
        </div>
        {createError && <p className="wb-error-text">{createError}</p>}
      </Card>

      <Card>
        <h3 className="wb-settings-title">Join with an invite code</h3>
        <p className="wb-settings-section-help">
          Enter the code a family admin shared with you to join their circle.
        </p>
        <div className="wb-row">
          <input
            className="wb-input"
            placeholder="Invite code"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') doJoin()
            }}
          />
          <Button size="sm" variant="secondary" loading={busy === 'join'} onClick={doJoin}>
            Join
          </Button>
        </div>
        {joinError && <p className="wb-error-text">{joinError}</p>}
      </Card>
    </div>
  )
}

function PageHeader({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="wb-page-header">
      <div>
        <h1 className="wb-page-title">{title}</h1>
        <p className="wb-page-subtitle">{subtitle}</p>
      </div>
    </div>
  )
}

function roleLabel(role: Role): string {
  switch (role) {
    case 'admin':
      return 'the admin'
    case 'child':
      return 'a child'
    default:
      return 'a member'
  }
}
