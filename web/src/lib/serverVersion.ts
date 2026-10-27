import React from 'react'
import { getServerVersion } from './api'

/** The running server's release (a git tag such as v0.7.3), or null until known. */
export function useServerVersion(): string | null {
  const [version, setVersion] = React.useState<string | null>(null)
  React.useEffect(() => {
    let cancelled = false
    getServerVersion()
      .then((r) => {
        if (!cancelled) setVersion(r.version)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [])
  return version
}
