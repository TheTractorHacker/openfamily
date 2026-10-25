// Users page — platform-wide account directory: create users, assign families,
// change roles, and reset passwords. Complements Families (group-centric) with
// a user-centric view that also includes accounts with no family.

import React from 'react'
import {
  assignUser,
  createUser,
  listFamilies,
  listUsers,
  resetUserPassword,
  updateUser,
  updateUserRole,
} from '../lib/api'
import { useAsync, isAccessDenied } from '../lib/useAsync'
import {
  AccessDenied,
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorState,
  Spinner,
} from '../components/primitives'
import { formatDate, initialsOf } from '../lib/format'
import type { AdminUser, Family, Role } from '../lib/types'
import './pages.css'
import './UsersPage.css'

const roles: Role[] = ['admin', 'member', 'child']

export function UsersPage() {
  const usersQuery = useAsync(listUsers, [])
  const families = useAsync(listFamilies, [])
  const [users, setUsers] = React.useState<AdminUser[]>([])

  React.useEffect(() => {
    if (usersQuery.data) setUsers(usersQuery.data)
  }, [usersQuery.data])

  if (isAccessDenied(usersQuery.error) || isAccessDenied(families.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  if ((usersQuery.loading && users.length === 0) || (families.loading && !families.data)) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading users…
        </div>
      </div>
    )
  }

  if (usersQuery.error || families.error) {
    return (
      <div className="wb-page">
        <ErrorState
          title="Couldn’t load users"
          description={usersQuery.error?.message ?? families.error?.message ?? 'Request failed'}
          onRetry={() => {
            usersQuery.refetch()
            families.refetch()
          }}
        />
      </div>
    )
  }

  const familyList = families.data ?? []
  const replaceUser = (updated: AdminUser) => {
    setUsers((current) => current.map((user) => (user.id === updated.id ? updated : user)))
  }

  return (
    <div className="wb-page">
      <div className="wb-page-header">
        <div>
          <h1 className="wb-page-title">Users</h1>
          <p className="wb-page-subtitle">
            Create accounts and manage family membership and roles.
          </p>
        </div>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => {
            usersQuery.refetch()
            families.refetch()
          }}
        >
          Refresh
        </Button>
      </div>

      <CreateUserCard
        families={familyList}
        onCreated={(user) =>
          setUsers((current) =>
            [...current, user].sort((a, b) => a.name.localeCompare(b.name)),
          )
        }
      />

      {users.length === 0 ? (
        <EmptyState
          title="No users yet"
          description="Create an account above, or wait for someone to register with an invite code."
        />
      ) : (
        <Card padded={false}>
          <div className="wb-user-table-wrap">
            <table className="wb-table wb-user-table">
              <thead>
                <tr>
                  <th>User</th>
                  <th>Family</th>
                  <th>Role</th>
                  <th>Created</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {users.map((user) => (
                  <UserRow
                    key={user.id}
                    user={user}
                    families={familyList}
                    onUpdated={replaceUser}
                  />
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  )
}

function CreateUserCard({
  families,
  onCreated,
}: {
  families: Family[]
  onCreated: (user: AdminUser) => void
}) {
  const [name, setName] = React.useState('')
  const [email, setEmail] = React.useState('')
  const [password, setPassword] = React.useState('')
  const [role, setRole] = React.useState<Role>('member')
  const [familyId, setFamilyId] = React.useState('')
  const [error, setError] = React.useState<string | null>(null)
  const [saving, setSaving] = React.useState(false)

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setSaving(true)
    setError(null)
    try {
      const user = await createUser({
        email,
        password,
        name,
        role,
        family_id: familyId || undefined,
      })
      onCreated(user)
      setName('')
      setEmail('')
      setPassword('')
      setRole('member')
      setFamilyId('')
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not create user')
    } finally {
      setSaving(false)
    }
  }

  return (
    <Card className="wb-create-card">
      <div className="wb-section-heading">
        <div>
          <h2>Create user</h2>
          <p>Accounts can be assigned to a family immediately, bypassing invite codes.</p>
        </div>
      </div>
      <form className="wb-form-grid" onSubmit={submit}>
        <label className="wb-field">
          <span className="wb-label">Name</span>
          <input
            className="wb-input"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            maxLength={120}
          />
        </label>
        <label className="wb-field">
          <span className="wb-label">Email</span>
          <input
            className="wb-input"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label className="wb-field">
          <span className="wb-label">Password</span>
          <input
            className="wb-input"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            minLength={8}
          />
        </label>
        <label className="wb-field">
          <span className="wb-label">Role</span>
          <select className="wb-select" value={role} onChange={(e) => setRole(e.target.value as Role)}>
            {roles.map((value) => (
              <option key={value} value={value}>
                {value}
              </option>
            ))}
          </select>
        </label>
        <label className="wb-field">
          <span className="wb-label">Family</span>
          <select className="wb-select" value={familyId} onChange={(e) => setFamilyId(e.target.value)}>
            <option value="">No family yet</option>
            {families.map((family) => (
              <option key={family.id} value={family.id}>
                {family.name}
              </option>
            ))}
          </select>
        </label>
        <div className="wb-form-submit">
          <Button type="submit" loading={saving}>
            Create user
          </Button>
        </div>
      </form>
      {error && <p className="wb-error-text wb-create-error">{error}</p>}
    </Card>
  )
}

function UserRow({
  user,
  families,
  onUpdated,
}: {
  user: AdminUser
  families: Family[]
  onUpdated: (user: AdminUser) => void
}) {
  const [familyId, setFamilyId] = React.useState(user.family_id ?? '')
  const [role, setRole] = React.useState<Role>(user.role)
  const [saving, setSaving] = React.useState(false)
  const [message, setMessage] = React.useState<string | null>(null)
  const [editing, setEditing] = React.useState(false)

  React.useEffect(() => {
    setFamilyId(user.family_id ?? '')
    setRole(user.role)
  }, [user.family_id, user.role])

  const save = async () => {
    setSaving(true)
    setMessage(null)
    try {
      let updated = user
      if (familyId !== (user.family_id ?? '')) {
        updated = await assignUser(user.id, familyId || null)
      }
      if (role !== updated.role) {
        updated = await updateUserRole(user.id, role)
      }
      onUpdated(updated)
      setMessage('Saved')
    } catch (e: unknown) {
      setMessage(e instanceof Error ? e.message : 'Could not update user')
    } finally {
      setSaving(false)
    }
  }

  const resetPassword = async () => {
    const password = window.prompt(`New password for ${user.email} (minimum 8 characters)`)
    if (!password) return
    setMessage(null)
    try {
      await resetUserPassword(user.id, password)
      setMessage('Password reset')
    } catch (e: unknown) {
      setMessage(e instanceof Error ? e.message : 'Could not reset password')
    }
  }

  return (
    <tr>
      <td>
        <div className="wb-member-cell">
          <span className="wb-member-dot">{initialsOf(user.name)}</span>
          <span>
            <div className="wb-member-name">
              {user.name}
              {user.platform_admin && (
                <Badge tone="pink">Platform admin</Badge>
              )}
            </div>
            <div className="wb-member-email">{user.email}</div>
          </span>
        </div>
      </td>
      <td>
        <select
          className="wb-select wb-inline-select"
          value={familyId}
          onChange={(e) => setFamilyId(e.target.value)}
        >
          <option value="">No family</option>
          {families.map((family) => (
            <option key={family.id} value={family.id}>
              {family.name}
            </option>
          ))}
        </select>
      </td>
      <td>
        <select
          className="wb-select wb-inline-select"
          value={role}
          onChange={(e) => setRole(e.target.value as Role)}
        >
          {roles.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </select>
      </td>
      <td className="wb-muted">{formatDate(user.created_at)}</td>
      <td>
        <div className="wb-row-actions">
          <Button size="sm" onClick={save} loading={saving}>
            Save
          </Button>
          <Button size="sm" variant="secondary" onClick={() => setEditing(true)}>
            Edit
          </Button>
          <Button size="sm" variant="ghost" onClick={resetPassword}>
            Reset password
          </Button>
          {message && (
            <span className="wb-row-message" role="status">
              {message}
            </span>
          )}
        </div>
        {editing && (
          <EditUserDialog
            user={user}
            onClose={() => setEditing(false)}
            onSaved={(updated) => {
              onUpdated(updated)
              setMessage('Details saved')
              setEditing(false)
            }}
          />
        )}
      </td>
    </tr>
  )
}

// EditUserDialog edits name, email and phone in a native modal <dialog>:
// showModal() traps focus, Esc closes it, and focus returns to the Edit button.
function EditUserDialog({
  user,
  onClose,
  onSaved,
}: {
  user: AdminUser
  onClose: () => void
  onSaved: (user: AdminUser) => void
}) {
  const dialogRef = React.useRef<HTMLDialogElement>(null)
  const nameRef = React.useRef<HTMLInputElement>(null)
  const [name, setName] = React.useState(user.name)
  const [email, setEmail] = React.useState(user.email)
  const [phone, setPhone] = React.useState(user.phone ?? '')
  const [error, setError] = React.useState<string | null>(null)
  const [saving, setSaving] = React.useState(false)

  React.useEffect(() => {
    const dialog = dialogRef.current
    if (dialog && !dialog.open) dialog.showModal()
    nameRef.current?.focus()
  }, [])

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    const patch: { name?: string; email?: string; phone?: string } = {}
    if (name.trim() !== user.name) patch.name = name
    if (email.trim().toLowerCase() !== user.email) patch.email = email
    if (phone.trim() !== (user.phone ?? '')) patch.phone = phone
    if (Object.keys(patch).length === 0) {
      onClose()
      return
    }
    setSaving(true)
    setError(null)
    try {
      onSaved(await updateUser(user.id, patch))
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not update user')
      setSaving(false)
    }
  }

  const emailChanging = email.trim().toLowerCase() !== user.email
  const titleId = `edit-user-${user.id}`

  return (
    <dialog
      ref={dialogRef}
      className="wb-dialog"
      aria-labelledby={titleId}
      onCancel={(e) => {
        e.preventDefault()
        if (!saving) onClose()
      }}
      onClick={(e) => {
        if (e.target === dialogRef.current && !saving) onClose()
      }}
    >
      <form onSubmit={submit} className="wb-dialog-body">
        <h2 id={titleId} className="wb-dialog-title">
          Edit {user.name}
        </h2>
        <label className="wb-field">
          <span className="wb-label">Name</span>
          <input
            ref={nameRef}
            className="wb-input"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            maxLength={120}
          />
        </label>
        <label className="wb-field">
          <span className="wb-label">Email</span>
          <input
            className="wb-input"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            aria-describedby={emailChanging ? `${titleId}-email-note` : undefined}
          />
        </label>
        {emailChanging && (
          <p id={`${titleId}-email-note`} className="wb-muted wb-dialog-note">
            Changing the email signs this user out of every device.
          </p>
        )}
        <label className="wb-field">
          <span className="wb-label">Phone</span>
          <input
            className="wb-input"
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder="+15551234567 (leave empty to clear)"
          />
        </label>
        {error && (
          <p className="wb-error-text" role="alert">
            {error}
          </p>
        )}
        <div className="wb-dialog-actions">
          <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button type="submit" loading={saving}>
            Save changes
          </Button>
        </div>
      </form>
    </dialog>
  )
}
