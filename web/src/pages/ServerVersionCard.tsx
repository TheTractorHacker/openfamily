import React from 'react'
import { getServerVersion } from '../lib/api'
import { Card, Mono } from '../components/primitives'

/**
 * Read-only display of the running server version. The server cannot update
 * itself; upgrades are run on the host with scripts/upgrade.sh.
 */
export function ServerVersionCard() {
  const [version, setVersion] = React.useState<string | null>(null)

  React.useEffect(() => {
    getServerVersion()
      .then((v) => setVersion(v.version))
      .catch(() => setVersion(null))
  }, [])

  const shown = version && version !== 'dev' ? version : null

  return (
    <Card className="wb-update-card">
      <h3 className="wb-settings-title">Server version</h3>
      <p className="wb-settings-section-help">
        To upgrade, run <code>./scripts/upgrade.sh</code> on the server host.
      </p>
      <div className="wb-update-ref">
        <span className="wb-update-ref-label">Running version</span>
        {shown ? <Mono truncate="none">{shown}</Mono> : <span className="wb-update-ref-unknown">Not reported</span>}
      </div>
    </Card>
  )
}
