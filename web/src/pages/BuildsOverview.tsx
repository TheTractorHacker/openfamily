// Every installable file of the latest release (Android APK/AAB and the
// unsigned iOS IPA) with size, checksum and date, install steps for both
// platforms, and the older releases.

import React from 'react'
import { ApiError, downloadApk, downloadIpa, getBuildsOverview, type BuildAsset } from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { Badge, Button, Card, ErrorState, Mono, Spinner } from '../components/primitives'
import { formatBytes } from '../lib/format'
import { REPO_URL } from '../lib/brand'

const KIND_LABEL = { apk: 'Android APK', aab: 'Android bundle (AAB)', ipa: 'iPhone (unsigned IPA)' } as const

function dateText(iso?: string): string {
  const d = iso ? new Date(iso) : null
  return d && !Number.isNaN(d.getTime()) ? d.toLocaleDateString(undefined, { dateStyle: 'medium' }) : 'Not reported'
}

function Sha({ value }: { value?: string }) {
  const [copied, setCopied] = React.useState(false)
  if (!value) return <span className="wb-audit-sub">Not published</span>
  return (
    <span className="wb-build-sha">
      <Mono truncate="none" title={value}>{value.slice(0, 12)}…{value.slice(-6)}</Mono>{' '}
      <button type="button" className="wb-build-copy" aria-label="Copy SHA-256"
        onClick={() => void navigator.clipboard?.writeText(value).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1500) })}>
        {copied ? 'Copied' : 'Copy'}
      </button>
    </span>
  )
}

export function BuildsOverview() {
  const q = useAsync(getBuildsOverview, [])
  const [busy, setBusy] = React.useState<string | null>(null)
  const [err, setErr] = React.useState<string | null>(null)

  const download = async (a: BuildAsset) => {
    setBusy(a.name)
    setErr(null)
    try {
      const blob = await (a.kind === 'ipa' ? downloadIpa() : downloadApk())
      const url = URL.createObjectURL(blob)
      const el = document.createElement('a')
      el.href = url
      el.download = a.name
      document.body.appendChild(el)
      el.click()
      el.remove()
      URL.revokeObjectURL(url)
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : 'Download failed')
    } finally {
      setBusy(null)
    }
  }

  if (q.loading && !q.data) return <div className="wb-page-loading"><Spinner /> Loading builds…</div>
  if (q.error) return <ErrorState title="Couldn’t load builds" description={q.error.message} onRetry={q.refetch} />
  const d = q.data
  if (!d?.configured) return <Card><p className="wb-help">Set <code>APK_GITHUB_REPO</code> on the server to list releases here.</p></Card>
  if (d.error || !d.overview) return <ErrorState title="Release list unavailable" description={d.error ?? 'No release found.'} onRetry={q.refetch} />
  const ov = d.overview
  const hasIpa = ov.assets.some((a) => a.kind === 'ipa')

  return (
    <div className="wb-builds-all">
      <Card padded={false} className="wb-build-files-card">
        <div className="wb-build-files-head">
          <h2 className="wb-build-release-title">All files in {ov.latest.tag_name}</h2>
          <span className="wb-audit-sub">Released {dateText(ov.latest.published_at)}</span>
        </div>
        <div className="wb-audit-tablewrap">
          <table className="wb-table wb-build-table">
            <thead>
              <tr><th>Platform</th><th>File</th><th>Size</th><th>SHA-256</th><th aria-label="Download" /></tr>
            </thead>
            <tbody>
              {ov.assets.map((a) => (
                <tr key={a.name}>
                  <td>{KIND_LABEL[a.kind]}</td>
                  <td className="wb-build-filename">{a.name}</td>
                  <td>{formatBytes(a.size)}</td>
                  <td><Sha value={a.sha256} /></td>
                  <td>
                    {a.kind === 'aab' ? <Badge tone="grey">Play Store upload</Badge> : (
                      <Button size="sm" variant="secondary" loading={busy === a.name} onClick={() => void download(a)}>Download</Button>
                    )}
                  </td>
                </tr>
              ))}
              {!hasIpa && (
                <tr><td>iPhone (unsigned IPA)</td><td colSpan={4} className="wb-audit-sub">Not attached to this release yet. The iOS build is added by a separate build job and may arrive later.</td></tr>
              )}
            </tbody>
          </table>
        </div>
        {err && <p className="wb-error-text" role="alert">{err}</p>}
      </Card>

      <div className="wb-builds-grid">
        <Card>
          <h3 className="wb-build-info-title">Install on iPhone (sideload)</h3>
          <ol className="wb-build-install-steps">
            <li>Download the unsigned <code>.ipa</code> on a computer.</li>
            <li>Install it with <a href="https://altstore.io" target="_blank" rel="noreferrer">AltStore</a> or <a href="https://sideloadly.io" target="_blank" rel="noreferrer">Sideloadly</a>, signing in with your Apple ID.</li>
            <li>Free Apple IDs must refresh the install every 7 days; AltStore can do this automatically.</li>
          </ol>
          <p className="wb-build-info-foot">Details: <a href="#/documents">Documents</a> or the <a href={`${REPO_URL}/blob/main/docs/design/IOS_RELEASE.md`} target="_blank" rel="noreferrer">iOS release notes</a>. Public link for invitees: <code>/app.ipa</code>.</p>
        </Card>
        <Card>
          <h3 className="wb-build-info-title">Older releases</h3>
          {ov.older.length === 0 ? <p className="wb-help">No older releases.</p> : (
            <ul className="wb-build-older">
              {ov.older.map((r) => (
                <li key={r.tag_name}>
                  <a href={r.html_url} target="_blank" rel="noreferrer"><strong>{r.tag_name}</strong></a>{' '}
                  <span className="wb-audit-sub">{dateText(r.published_at)} · {r.assets.map((a) => a.kind.toUpperCase()).join(', ') || 'no files'}</span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </div>
  )
}
