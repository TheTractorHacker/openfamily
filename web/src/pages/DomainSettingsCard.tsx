// Domain status card — platform admin only. A read-only mirror of how the
// server is addressed (SITE_ADDRESS / PUBLIC_BASE_URL from the deployment's
// .env) plus live DNS and HTTPS health checks. The API never edits these
// values: this card tells the operator whether the current domain setup works
// and links to the setup guide, which also covers servers still on a local
// address.

import React from 'react'
import { ApiError, getDomainStatus } from '../lib/api'
import type { DomainCheck, DomainStatus } from '../lib/types'
import { Badge, Button, Card, CopyButton, Mono } from '../components/primitives'

const CUSTOM_DOMAIN_DOCS_URL =
  'https://github.com/TheTractorHacker/openfamily/blob/main/docs/custom-domain.md'

function messageFromError(error: unknown, fallback: string): string {
  if (error instanceof ApiError) return error.message || fallback
  if (error instanceof Error) return error.message || fallback
  return fallback
}

function CheckRow({ label, check }: { label: string; check?: DomainCheck }) {
  if (!check) return null

  let mark = '—'
  if (check.status === 'ok') mark = '✓'
  else if (check.status === 'fail') mark = '✕'

  const tone = check.status === 'ok' ? 'wb-domain-check-ok' : check.status === 'fail' ? 'wb-domain-check-fail' : ''

  return (
    <div className="wb-domain-check">
      <span className={`wb-domain-check-mark ${tone}`} aria-hidden="true">
        {mark}
      </span>
      <div>
        <span className="wb-domain-check-label">{label}</span>{' '}
        <span className={`wb-domain-check-detail ${tone}`}>
          {check.detail || (check.status === 'skipped' ? 'Skipped.' : '')}
        </span>
      </div>
    </div>
  )
}

export function DomainSettingsCard() {
  const [status, setStatus] = React.useState<DomainStatus | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [loadError, setLoadError] = React.useState<string | null>(null)

  const refresh = React.useCallback(async () => {
    setLoading(true)
    setLoadError(null)
    try {
      setStatus(await getDomainStatus())
    } catch (error) {
      setLoadError(messageFromError(error, 'Could not load domain status.'))
    } finally {
      setLoading(false)
    }
  }, [])

  React.useEffect(() => {
    void refresh()
  }, [refresh])

  const custom = Boolean(status?.custom_domain)
  const serverUrl = typeof window !== 'undefined' ? window.location.origin : ''

  return (
    <Card>
      <div className="wb-settings-title-row">
        <h3 className="wb-settings-title">Custom domain</h3>
        <Badge tone={loading && !status ? 'grey' : custom ? 'green' : 'grey'} dot>
          {loading && !status ? 'Checking…' : custom ? 'Configured' : 'Not configured'}
        </Badge>
      </div>
      <p className="wb-settings-section-help">
        Serving on your own domain gives every device automatic HTTPS via Let&apos;s Encrypt.
      </p>

      {loadError && (
        <div className="wb-profile-load-error" role="alert">
          <span>{loadError}</span>
          <Button type="button" variant="secondary" size="sm" onClick={() => void refresh()}>
            Try again
          </Button>
        </div>
      )}

      {!loadError && (
        <>
          {custom && status?.hostname ? (
            <dl className="wb-settings-list wb-settings-list-row">
              <div>
                <dt>Address</dt>
                <dd className="wb-settings-mono">
                  <Mono truncate="none" max={40}>{status.hostname}</Mono>
                  <CopyButton value={status.hostname} label="Copy domain" />
                </dd>
              </div>
              <div>
                <dt>Site address (env)</dt>
                <dd className="wb-settings-mono">
                  <Mono truncate="none" max={40}>{status.site_address}</Mono>
                </dd>
              </div>
              {status.public_base_url && (
                <div>
                  <dt>SMS link origin</dt>
                  <dd className="wb-settings-mono">
                    <Mono truncate="none" max={40}>{status.public_base_url}</Mono>
                  </dd>
                </div>
              )}
            </dl>
          ) : (
            <p className="wb-settings-section-help">
              This server is currently reached as{' '}
              <span className="wb-settings-mono">
                <Mono truncate="none" max={48}>
                  {serverUrl || status?.site_address || 'a local address'}
                </Mono>
              </span>
              . It works, but browsers and phones will warn about the missing certificate.
            </p>
          )}

          {custom && (
            <div className="wb-domain-checks">
              <CheckRow label="DNS:" check={status?.dns} />
              <CheckRow label="HTTPS:" check={status?.https} />
            </div>
          )}
        </>
      )}

      <p className="wb-domain-docs-row">
        <a href={CUSTOM_DOMAIN_DOCS_URL} target="_blank" rel="noreferrer">
          How to set up a custom domain ↗
        </a>
        <Button type="button" variant="ghost" size="sm" loading={loading} onClick={() => void refresh()}>
          Re-run checks
        </Button>
      </p>
    </Card>
  )
}
