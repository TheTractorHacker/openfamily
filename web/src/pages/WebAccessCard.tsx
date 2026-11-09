// Settings > Security: web access from any browser (docs/design/WEB_VIEWER_ANYWHERE.md).
// The admin switch, this account's status, and removing the stored sealed key.
// Setting up and unlocking happen on the Private circles page.

import React from 'react'
import { ApiError, e2eeHttp, getViewerVaultAdmin, setViewerVaultAdmin, type ViewerVaultAdmin } from '../lib/api'
import { vaultStatus, deleteVault, type VaultStatus } from '../e2ee/accountAccess'
import { Badge, Button, Card } from '../components/primitives'

export function WebAccessCard({ isPlatformAdmin }: { isPlatformAdmin: boolean }) {
  const [admin, setAdmin] = React.useState<ViewerVaultAdmin | null>(null)
  const [mine, setMine] = React.useState<VaultStatus | null>(null)
  const [busy, setBusy] = React.useState(false)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)

  const load = React.useCallback(() => {
    vaultStatus(e2eeHttp).then(setMine, () => setMine(null))
    if (isPlatformAdmin) getViewerVaultAdmin().then(setAdmin, () => setAdmin(null))
  }, [isPlatformAdmin])
  React.useEffect(load, [load])

  async function act(f: () => Promise<unknown>, ok: string) {
    setBusy(true)
    setMessage(null)
    try {
      await f()
      setMessage({ tone: 'success', text: ok })
      load()
    } catch (err) {
      setMessage({ tone: 'error', text: err instanceof ApiError || err instanceof Error ? err.message : 'Could not save' })
    } finally {
      setBusy(false)
    }
  }

  if (!isPlatformAdmin && !mine?.exists) return null
  return (
    <Card data-testid="web-access-card">
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Web access from any browser</h3>
        {mine && (mine.exists ? <Badge tone="green" dot>Set up</Badge> : <Badge tone="neutral">Not set up</Badge>)}
      </div>
      <p className="wb-settings-section-help">
        Lets an admin open Private circles from any browser: one viewer key, approved by a phone once, sealed with a vault
        passphrase only the admin knows and stored on the server. The server cannot open it. Unlocking needs the account
        password (and two-factor code) and then the vault passphrase; the phones are told when a new browser unlocks.
      </p>
      {admin && (
        <div className="wb-settings-section wb-settings-section-flush">
          <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input
              type="checkbox"
              checked={admin.enabled && !admin.off_by_operator}
              disabled={busy || admin.off_by_operator}
              onChange={(e) => {
                const on = e.target.checked
                void act(() => setViewerVaultAdmin(on).then(setAdmin), on ? 'Web access from any browser is on.' : 'Web access from any browser is off. Nobody can unlock until it is turned on again.')
              }}
            />
            Allow web access from any browser (admins only)
          </label>
          {admin.off_by_operator && <p className="wb-help">Switched off on the server with E2EE_VIEWER_VAULT=off.</p>}
          {!admin.pepper_available && !admin.off_by_operator && (
            <p className="wb-error-text" role="status">
              Unavailable: {admin.pepper_error || 'the vault key file cannot be read'}.
            </p>
          )}
          <p className="wb-help">
            <strong>Back up the vault key file</strong> (<code>viewer-vault-pepper</code> in the server-device volume) separately
            from database backups. Without it, stored web access cannot be opened and has to be set up again; with it inside
            the same backup as the database, a stolen backup is easier to attack.
          </p>
          <p className="wb-help">{admin.vaults} account(s) have web access set up.</p>
        </div>
      )}
      {mine?.exists && (
        <div className="wb-settings-section">
          <p className="wb-help">
            Your web access was set up {mine.created_at ? new Date(mine.created_at).toLocaleString() : ''}
            {mine.last_opened_at ? `, last unlocked ${new Date(mine.last_opened_at).toLocaleString()}` : ', never unlocked yet'}.
          </p>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <Button size="sm" variant="secondary" onClick={() => (window.location.hash = '#/private')}>
              Open Private circles
            </Button>
            <Button
              size="sm"
              variant="danger"
              loading={busy}
              onClick={() => {
                if (window.confirm('Remove the stored sealed key? No browser can unlock it afterwards. Also revoke the web viewer on your phone so its key stops working.')) {
                  void act(() => deleteVault(e2eeHttp), 'Removed. Revoke the web viewer on your phone too.')
                }
              }}
            >
              Remove web access
            </Button>
          </div>
        </div>
      )}
      {message && <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">{message.text}</p>}
    </Card>
  )
}
