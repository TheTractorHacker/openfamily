// Builds — everything the latest GitHub release offers for installing the app:
// Android APK/AAB, Wear OS APK, the unsigned iOS IPA, the SBOM and checksums,
// plus the five releases before it. Read-only; downloads come from the public
// release (or the server's /app.apk and /app.ipa for the latest build).

import React from 'react'
import { getAdminBuilds } from '../lib/api'
import { isAccessDenied } from '../lib/useAsync'
import { ApiError } from '../lib/api'
import type { AdminBuilds, BuildAsset, BuildRelease } from '../lib/types'
import { AccessDenied, Badge, Button, Card, CopyButton, ErrorState } from '../components/primitives'
import { Alert, PageHeader, Section } from '../components/patterns'
import { REPO_URL } from '../lib/brand'
import { abiLabel, formatSize, IOS_DOC_PATH, releaseSlots, shareUrl, shortSha } from '../lib/builds'
import { qrSvg } from '../lib/qr'
import './pages.css'
import './BuildsPage.css'

function formatDate(value?: string): string {
  if (!value) return '—'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return '—'
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(d)
}

const KIND_LABEL: Record<string, string> = {
  android_apk: 'Android phone (APK)',
  android_aab: 'Android bundle (AAB)',
  wear_apk: 'Wear OS watch (APK)',
  ios_ipa: 'iPhone (unsigned IPA)',
  sbom: 'Software list (SBOM)',
  checksums: 'Checksums (SHA-256)',
  other: 'Other file',
}

function kindText(a: BuildAsset): string {
  if (a.kind === 'android_apk' || a.kind === 'wear_apk') return `${KIND_LABEL[a.kind]} · ${abiLabel(a.abi)}`
  return KIND_LABEL[a.kind] ?? a.name
}

export function BuildsPage() {
  const [data, setData] = React.useState<AdminBuilds | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [failure, setFailure] = React.useState<{ status: number; message: string } | null>(null)

  const load = React.useCallback(async (refresh: boolean) => {
    setLoading(true)
    try {
      setData(await getAdminBuilds(refresh))
      setFailure(null)
    } catch (e) {
      setFailure(
        e instanceof ApiError
          ? { status: e.status, message: e.message }
          : { status: 0, message: e instanceof Error ? e.message : 'Could not load releases.' },
      )
    } finally {
      setLoading(false)
    }
  }, [])

  React.useEffect(() => {
    void load(false)
  }, [load])

  if (isAccessDenied(failure)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }

  const latest = data?.releases[0]
  const older = data?.releases.slice(1, 6) ?? []

  return (
    <div className="wb-page">
      <PageHeader
        title="App builds"
        subtitle="Install Orbitly on Android, Wear OS and iPhone from the newest release."
        actions={
          <Button variant="secondary" size="sm" loading={loading && !!data} onClick={() => void load(true)}>
            Refresh
          </Button>
        }
      />

      {failure && !data && (
        <ErrorState title="Couldn’t load the release list" description={failure.message} onRetry={() => void load(true)} />
      )}

      {data?.error && (
        <Alert tone="warning" title={data.stale ? 'Showing the last list we could get' : 'GitHub could not be reached'}>
          {data.error}
          {data.stale && data.fetched_at && ` (list from ${new Date(data.fetched_at).toLocaleString()})`}
        </Alert>
      )}

      {loading && !data && !failure && <BuildsSkeleton />}

      {data && !latest && !data.error && (
        <Card>
          <p className="wb-build-empty">No published release was found for {data.repo}.</p>
        </Card>
      )}

      {data && latest && (
        <>
          <LatestRelease rel={latest} data={data} />
          <InstallHelp rel={latest} origin={window.location.origin} />
          {older.length > 0 && (
            <Section title="Earlier releases" description="The five releases before the latest.">
              <div className="wb-build-older">
                {older.map((rel) => (
                  <details key={rel.tag_name} className="wb-build-old">
                    <summary>
                      <span className="wb-build-old-tag">{rel.tag_name}</span>
                      <span className="wb-build-old-date">{formatDate(rel.published_at)}</span>
                      <span className="wb-build-old-count">{rel.assets.length} files</span>
                    </summary>
                    <AssetTable assets={orderedAssets(rel)} latestPaths={{}} origin={window.location.origin} />
                  </details>
                ))}
              </div>
            </Section>
          )}
        </>
      )}
    </div>
  )
}

function BuildsSkeleton() {
  return (
    <div className="wb-build-skeleton" aria-busy="true" aria-label="Loading releases">
      <div className="wb-skeleton" style={{ height: 120 }} />
      <div className="wb-skeleton wb-skeleton-row" />
      <div className="wb-skeleton wb-skeleton-row" />
      <div className="wb-skeleton wb-skeleton-row" />
    </div>
  )
}

function orderedAssets(rel: BuildRelease): BuildAsset[] {
  const s = releaseSlots(rel)
  return [...s.androidApks, ...(s.aab ? [s.aab] : []), ...s.wear, ...(s.ipa ? [s.ipa] : []), ...s.sbom, ...(s.checksums ? [s.checksums] : [])]
}

function LatestRelease({ rel, data }: { rel: BuildRelease; data: AdminBuilds }) {
  const s = releaseSlots(rel)
  const origin = window.location.origin
  const primaryApk = s.androidApks[0]
  const latestPaths: Record<string, string> = {}
  if (primaryApk) latestPaths[primaryApk.name] = data.public_apk
  if (s.ipa) latestPaths[s.ipa.name] = data.public_ipa

  return (
    <Card className="wb-build-latest">
      <div className="wb-build-latest-head">
        <div>
          <div className="wb-build-eyebrow">Latest release</div>
          <h2 className="wb-build-title">{rel.name?.trim() || rel.tag_name}</h2>
          <div className="wb-build-sub">
            {rel.tag_name} · published {formatDate(rel.published_at)}
            {rel.prerelease && <Badge tone="orange">pre-release</Badge>}
          </div>
        </div>
        {rel.html_url && (
          <a className="wb-build-link" href={rel.html_url} target="_blank" rel="noreferrer">
            Release notes on GitHub
          </a>
        )}
      </div>

      <div className="wb-build-platforms">
        <Platform title="Android phone and tablet" present={s.androidApks.length > 0} absent="No Android APK in this release.">
          <AssetTable assets={[...s.androidApks, ...(s.aab ? [s.aab] : [])]} latestPaths={latestPaths} origin={origin} />
          {s.androidApks.length > 1 && (
            <p className="wb-build-note">
              Several versions of the app are listed, one per phone type. If unsure, pick “All phones”, or “Most phones” for any
              phone from the last several years.
            </p>
          )}
        </Platform>

        <Platform title="Wear OS watch" present={s.wear.length > 0} absent="Not in this release.">
          <AssetTable assets={s.wear} latestPaths={{}} origin={origin} />
        </Platform>

        <Platform title="iPhone" present={!!s.ipa} absent="Not in this release.">
          {s.ipa && <AssetTable assets={[s.ipa]} latestPaths={latestPaths} origin={origin} />}
        </Platform>

        <div className="wb-build-platform">
          <h3 className="wb-build-platform-title">Apple Watch</h3>
          <p className="wb-build-absent">
            The Apple Watch app is not published as a download. It installs together with the iPhone app after it has been
            signed with an Apple developer account.
          </p>
        </div>

        <Platform title="Check your download" present={s.sbom.length > 0 || !!s.checksums} absent="Not in this release.">
          <AssetTable assets={[...s.sbom, ...(s.checksums ? [s.checksums] : [])]} latestPaths={{}} origin={origin} />
          <p className="wb-build-note">
            To check a file, run <code>sha256sum &lt;file&gt;</code> and compare it with the SHA-256 shown here.
          </p>
        </Platform>
      </div>
    </Card>
  )
}

function Platform({
  title,
  present,
  absent,
  children,
}: {
  title: string
  present: boolean
  absent: string
  children: React.ReactNode
}) {
  return (
    <div className="wb-build-platform">
      <h3 className="wb-build-platform-title">{title}</h3>
      {present ? children : <p className="wb-build-absent">{absent}</p>}
    </div>
  )
}

function AssetTable({
  assets,
  latestPaths,
  origin,
}: {
  assets: BuildAsset[]
  latestPaths: Record<string, string>
  origin: string
}) {
  return (
    <div className="wb-build-table" role="table" aria-label="Files">
      <div className="wb-build-tr wb-build-th" role="row">
        <span role="columnheader">File</span>
        <span role="columnheader">Version</span>
        <span role="columnheader">Size</span>
        <span role="columnheader">SHA-256</span>
        <span role="columnheader">Released</span>
        <span role="columnheader">Link</span>
      </div>
      {assets.map((a) => {
        const link = shareUrl(origin, a, latestPaths[a.name] ?? null)
        return (
          <div className="wb-build-tr" role="row" key={a.name}>
            <span role="cell" className="wb-build-file" data-label="File">
              <span className="wb-build-filename">{a.name}</span>
              <span className="wb-build-kind">{kindText(a)}</span>
            </span>
            <span role="cell" data-label="Version">{a.version || '—'}</span>
            <span role="cell" data-label="Size">{formatSize(a.size)}</span>
            <span role="cell" data-label="SHA-256" className="wb-build-sha">
              {a.sha256 ? (
                <>
                  <code title={a.sha256}>{shortSha(a.sha256)}…</code>
                  <CopyButton value={a.sha256} label={`Copy SHA-256 of ${a.name}`} />
                </>
              ) : (
                '—'
              )}
            </span>
            <span role="cell" data-label="Released">{formatDate(a.updated_at)}</span>
            <span role="cell" data-label="Link" className="wb-build-actions">
              {link ? (
                <>
                  <a className="wb-build-dl" href={link} download>
                    Download
                  </a>
                  <CopyButton value={link} label={`Copy download link for ${a.name}`} />
                </>
              ) : (
                '—'
              )}
            </span>
          </div>
        )
      })}
    </div>
  )
}

function InstallHelp({ rel, origin }: { rel: BuildRelease; origin: string }) {
  const s = releaseSlots(rel)
  const apkLink = origin + '/app.apk'
  const qr = React.useMemo(() => qrSvg(apkLink, 4, 2), [apkLink])
  return (
    <div className="wb-build-help">
      <Card className="wb-build-help-card">
        <h3 className="wb-build-help-title">Install on Android</h3>
        <div className="wb-build-android">
          {s.androidApks.length > 0 && (
            <div className="wb-build-qr">
              <div className="wb-build-qr-img" role="img" aria-label="QR code for the Android download" dangerouslySetInnerHTML={{ __html: qr }} />
              <span>Scan with the phone camera</span>
            </div>
          )}
          <ol>
            <li>Open the download link on the phone, or scan the code.</li>
            <li>Open the downloaded file. Android asks once to allow installs from your browser; allow it.</li>
            <li>Tap Install. Installing over the existing app keeps all settings.</li>
          </ol>
        </div>
        <p className="wb-build-note">
          Android may warn that the file did not come from the Play Store. That is expected for a family-run server. The SHA-256
          above proves the file is the one that was published.
        </p>
      </Card>

      <Card className="wb-build-help-card">
        <h3 className="wb-build-help-title">Install on iPhone</h3>
        <ol>
          <li>
            Download the <strong>unsigned IPA</strong> on a computer. iPhones refuse an unsigned app, so it must be signed with
            your own Apple ID first.
          </li>
          <li>
            Use <strong>AltStore</strong> or <strong>Sideloadly</strong> on a Mac or PC: connect the iPhone, pick the IPA, enter
            your Apple ID. The tool signs it and installs it.
          </li>
          <li>On the iPhone: Settings, General, VPN &amp; Device Management, trust your Apple ID.</li>
        </ol>
        <p className="wb-build-note">
          <strong>Limits:</strong> with a free Apple ID the app stops working after 7 days and must be installed again (AltStore
          can refresh it automatically while the computer is on), and at most 3 sideloaded apps are allowed. Lasting installs,
          TestFlight and the App Store need a paid Apple Developer account (99 USD a year).
        </p>
        <p className="wb-build-note">
          Step by step:{' '}
          <a href={`${REPO_URL}/blob/main/${IOS_DOC_PATH}`} target="_blank" rel="noreferrer">
            iOS release guide
          </a>
          {' · '}
          <a href={`${REPO_URL}/blob/main/docs/android-install-and-updates.md`} target="_blank" rel="noreferrer">
            Android install guide
          </a>
        </p>
      </Card>
    </div>
  )
}
