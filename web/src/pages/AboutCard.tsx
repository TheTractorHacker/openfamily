import React from 'react'
import { getServerVersion } from '../lib/api'
import { BRAND_DESCRIPTION, BRAND_NAME, BRAND_TAGLINE, REPO_URL, UPSTREAM_NAME, UPSTREAM_URL } from '../lib/brand'
import { docHash } from '../lib/docs'
import { Card, Mono } from '../components/primitives'

/** Settings > About: name, version, credit to the upstream project and the source offer. */
export function AboutCard() {
  const [version, setVersion] = React.useState<string | null>(null)
  React.useEffect(() => {
    getServerVersion()
      .then((v) => setVersion(v.version))
      .catch(() => setVersion(null))
  }, [])
  const shown = version && version !== 'dev' ? version : null

  return (
    <Card className="wb-update-card">
      <h3 className="wb-settings-title">About {BRAND_NAME}</h3>
      <p className="wb-settings-section-help">
        {BRAND_TAGLINE} {BRAND_DESCRIPTION}
      </p>
      <div className="wb-update-ref">
        <span className="wb-update-ref-label">Server version</span>
        {shown ? <Mono truncate="none">{shown}</Mono> : <span className="wb-update-ref-unknown">Not reported</span>}
      </div>
      <p className="wb-settings-section-help">
        Based on{' '}
        <a href={UPSTREAM_URL} target="_blank" rel="noopener noreferrer">
          {UPSTREAM_NAME}
        </a>{' '}
        by wheresfrank and contributors (AGPL-3.0). {BRAND_NAME} is free software under the GNU Affero General Public
        License v3.0. Everyone who uses this server may get its source code:{' '}
        <a href={REPO_URL} target="_blank" rel="noopener noreferrer">
          {REPO_URL.replace('https://', '')}
        </a>
        . More: <a href={docHash('about/credits-and-license.md')}>credits and license</a>.
      </p>
    </Card>
  )
}
