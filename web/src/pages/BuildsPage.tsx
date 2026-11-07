import React from 'react'
import { ApiError, downloadApk, getApkStatus } from '../lib/api'
import type { ApkReleaseInfo, ApkStatus } from '../lib/types'
import { Badge, Button, Card, Mono } from '../components/primitives'
import './pages.css'
import './BuildsPage.css'

function formatDate(value?: string): string {
  if (!value) return 'Not reported'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'Not reported'
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return 'Not reported'
  const megabytes = bytes / (1024 * 1024)
  return `${megabytes < 10 ? megabytes.toFixed(1) : Math.round(megabytes)} MB`
}

function releaseTitle(release?: ApkReleaseInfo): string {
  return release?.name?.trim() || release?.tag_name || 'Latest Android release'
}

export function BuildsPage() {
  const [status, setStatus] = React.useState<ApkStatus | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [loadError, setLoadError] = React.useState<string | null>(null)
  const [downloadState, setDownloadState] = React.useState<'idle' | 'downloading' | 'done' | 'error'>('idle')
  const [actionError, setActionError] = React.useState<string | null>(null)

  const loadRelease = React.useCallback(async () => {
    setLoadError(null)
    try {
      setStatus(await getApkStatus())
    } catch (error) {
      setLoadError(error instanceof ApiError ? error.message : 'Could not load release information.')
    } finally {
      setLoading(false)
    }
  }, [])

  React.useEffect(() => {
    void loadRelease()
  }, [loadRelease])

  const download = async () => {
    setActionError(null)
    setDownloadState('downloading')
    try {
      const blob = await downloadApk()
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = status?.release?.asset_name || 'openfamily.apk'
      document.body.appendChild(anchor)
      anchor.click()
      anchor.remove()
      URL.revokeObjectURL(url)
      setDownloadState('done')
    } catch (error) {
      setActionError(error instanceof ApiError ? error.message : 'Download failed')
      setDownloadState('error')
    }
  }

  const release = status?.release
  const releaseError = loadError || status?.release_error

  return (
    <div className="wb-page">
      <div className="wb-page-header wb-builds-page-header">
        <div>
          <h1 className="wb-page-title">Android builds</h1>
          <p className="wb-page-subtitle">Download and install the latest Orbitly release.</p>
        </div>
        <Button variant="secondary" size="sm" loading={loading} onClick={() => void loadRelease()}>
          Refresh release
        </Button>
      </div>

      <Card className="wb-build-release-card">
        <div className="wb-build-release-head">
          <div className="wb-build-release-heading">
            <span className="wb-build-app-icon" aria-hidden="true"><AndroidIcon /></span>
            <div>
              <div className="wb-build-eyebrow">Latest release</div>
              <h2 className="wb-build-release-title">
                {loading && !release ? 'Loading release…' : releaseTitle(release)}
              </h2>
              {release?.tag_name && release.name?.trim() && (
                <Mono truncate="none">{release.tag_name}</Mono>
              )}
            </div>
          </div>
          <Badge tone={release ? 'green' : releaseError ? 'red' : 'neutral'} dot={Boolean(release)}>
            {release ? 'Ready to install' : releaseError ? 'Release unavailable' : 'Checking…'}
          </Badge>
        </div>

        {releaseError && (
          <div className="wb-build-error" role="alert">
            <span>{releaseError}</span>
            <button type="button" onClick={() => void loadRelease()}>Try again</button>
          </div>
        )}

        <dl className="wb-build-meta">
          <div>
            <dt>Published</dt>
            <dd>{loading ? 'Checking…' : formatDate(release?.published_at)}</dd>
          </div>
          <div>
            <dt>Download size</dt>
            <dd>{loading ? 'Checking…' : formatBytes(release?.asset_size ?? 0)}</dd>
          </div>
          <div>
            <dt>File</dt>
            <dd className="wb-build-filename">{loading ? 'Checking…' : release?.asset_name || 'Not reported'}</dd>
          </div>
          <div>
            <dt>Platform</dt>
            <dd>Android APK</dd>
          </div>
        </dl>

        <div className="wb-build-actions">
          <Button
            onClick={() => void download()}
            disabled={downloadState === 'downloading'}
            loading={downloadState === 'downloading'}
            icon={<DownloadIcon />}
          >
            {downloadState === 'downloading' ? 'Downloading…' : 'Download APK'}
          </Button>
          {release?.html_url && (
            <a className="wb-build-release-link" href={release.html_url} target="_blank" rel="noreferrer">
              View release <ExternalIcon />
            </a>
          )}
        </div>

        {downloadState === 'done' && <p className="wb-build-download-message" role="status">Download started.</p>}
        {actionError && <p className="wb-error-text wb-build-action-error" role="alert">{actionError}</p>}
      </Card>

      <div className="wb-builds-grid">
        <Card className="wb-build-notes-card">
          <div className="wb-build-section-icon" aria-hidden="true"><NotesIcon /></div>
          <h3 className="wb-build-info-title">What’s in this release</h3>
          <p className={release?.body ? 'wb-build-release-notes' : 'wb-build-info-text'}>
            {release?.body?.trim() || 'Release notes have not been added for this build.'}
          </p>
        </Card>

        <Card className="wb-build-install-card">
          <div className="wb-build-section-icon" aria-hidden="true"><PhoneIcon /></div>
          <h3 className="wb-build-info-title">Install on Android</h3>
          <ol className="wb-build-install-steps">
            <li>Download the APK on your phone.</li>
            <li>Open the downloaded file and allow installs when prompted.</li>
            <li>Install over the existing app to keep your settings.</li>
          </ol>
          <p className="wb-build-info-foot">Android may warn that the file came from outside the Play Store.</p>
        </Card>
      </div>
    </div>
  )
}

function DownloadIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M12 3v12m0 0 4-4m-4 4-4-4M5 21h14" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function AndroidIcon() {
  return (
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
      <path d="M7 8h10a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Zm1-3-1.5-2M16 5l1.5-2M9 12h.01M15 12h.01" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  )
}

function ExternalIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M14 5h5v5m0-5-8 8M19 13v5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function NotesIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
      <path d="M7 4h10a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Zm2 5h6M9 13h6M9 17h4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  )
}

function PhoneIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
      <rect x="6" y="2.5" width="12" height="19" rx="2.5" stroke="currentColor" strokeWidth="1.7" />
      <path d="M10 18.5h4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  )
}
