// Renders the live map (src/map/MapView) in self-managed mode: the map fetches
// its own families + members and streams live updates, so the shell only needs
// to hand it the access token. The scope decides which API surface it talks
// to: platform admins get the server-wide view, everyone else gets the same
// family-scoped endpoints the mobile apps use.

import MapView from '../map/MapView'
import { ensureFreshAccessToken, getAccessToken } from '../lib/auth'
import { useMe } from '../lib/me'
import './MapArea.css'

export function MapArea() {
  const token = getAccessToken()
  const { isPlatformAdmin, loading } = useMe()

  if (!token) {
    return (
      <div className="wb-maparea wb-maparea-loading">
        <span className="wb-maparea-loading-text">Sign in to view the live map.</span>
      </div>
    )
  }

  // Wait for the identity so a regular user never briefly hits the admin
  // endpoints (and catches a 403) before the scope resolves.
  if (loading) {
    return (
      <div className="wb-maparea wb-maparea-loading">
        <span className="wb-maparea-loading-text">Loading…</span>
      </div>
    )
  }

  return (
    <div className="wb-maparea">
      <MapView token={token} getToken={ensureFreshAccessToken} scope={isPlatformAdmin ? 'admin' : 'family'} />
    </div>
  )
}
