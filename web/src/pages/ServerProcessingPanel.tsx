// "Server processing" panel for the Dashboard and Private circles pages:
// whether the server has its own key, and per circle who uses server
// processing, who keeps data on the phone, who has not chosen, and when data
// last arrived. Timestamps and counts only; no coordinates.

import { getProcessingOverview } from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { Badge, Card, Spinner } from '../components/primitives'
import { Alert } from '../components/patterns'
import { formatRelativeTime } from '../lib/format'

const LANE = { server: ['Server', 'green'], phone: ['Phone only', 'neutral'], not_chosen: ['Not chosen yet', 'orange'] } as const

function reason(lane: string, lastAt: string | null, today: number): string | null {
  if (lane === 'not_chosen') return 'Has not chosen yet. Ask them to open Orbitly and pick a processing option.'
  if (lane === 'phone') return 'Keeps data on the phone by choice, so the server shows nothing for them.'
  if (!lastAt) return 'Nothing received yet. Likely reasons: the phone is locked or offline, the app is old, or the app has not been opened since they chose server processing.'
  if (today === 0 && Date.now() - Date.parse(lastAt) > 6 * 3600_000) return 'Nothing received today. The phone may be off or the app closed.'
  return null
}

export function ServerProcessingPanel() {
  const q = useAsync(getProcessingOverview, [])
  const d = q.data
  return (
    <section aria-labelledby="srvproc-h" className="wb-srvproc">
      <h2 id="srvproc-h" className="wb-audit-h2">Server processing</h2>
      {q.loading && !d ? (
        <div className="wb-page-loading"><Spinner /> Loading…</div>
      ) : q.error ? (
        <Alert tone="danger" title="Couldn’t load server processing">{q.error.message}</Alert>
      ) : d ? (
        <>
          <Card>
            <strong>Server key: </strong>
            {d.server_key.state === 'approved' && <Badge tone="green" dot>Approved{d.server_key.device ? ` (${d.server_key.device})` : ''}</Badge>}
            {d.server_key.state === 'waiting' && <Badge tone="orange" dot>Waiting for an admin phone to approve it</Badge>}
            {d.server_key.state === 'none' && <Badge tone="grey">Not set up</Badge>}
            <p className="wb-help">Server processing only works for circles where the server key is approved and the circle allows it. <a href="#/fleet">Open Fleet health</a> to check phones.</p>
          </Card>
          {d.circles.length === 0 ? (
            <p className="wb-help">No circle uses server processing yet. Turn it on for a Private circle in the app; members can opt out.</p>
          ) : (
            d.circles.map((c) => (
              <Card key={c.id} padded={false}>
                <div className="wb-srvproc-head"><strong>{c.name}</strong> <span className="wb-audit-sub">{c.members.length} member{c.members.length === 1 ? '' : 's'}</span></div>
                <div className="wb-audit-tablewrap">
                  <table className="wb-table wb-srvproc-table">
                    <thead><tr><th>Person</th><th>Uses</th><th>Last data</th><th>Points today</th></tr></thead>
                    <tbody>
                      {c.members.map((m) => {
                        const [label, tone] = LANE[m.lane]
                        const why = reason(m.lane, m.last_data_at, m.points_today)
                        return (
                          <tr key={m.user_id}>
                            <td>{m.name}{why && <div className="wb-audit-sub">{why}</div>}</td>
                            <td><Badge tone={tone}>{label}</Badge></td>
                            <td>{m.last_data_at ? formatRelativeTime(m.last_data_at) : 'Nothing yet'}</td>
                            <td>{m.lane === 'server' ? m.points_today : '—'}</td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              </Card>
            ))
          )}
        </>
      ) : null}
    </section>
  )
}
