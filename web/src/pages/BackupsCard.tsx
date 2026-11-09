// Backups card (Settings > Backups): destinations (never credentials), last
// success / failure, schedule, retention, plus "Back up now" and "Test S3
// connection". Both buttons only queue a request for the `backup` compose
// service (started by a plain `docker compose up -d`), which owns the S3
// credentials and dump tools.

import React from 'react'
import { ApiError, getAdminBackups, runBackupNow, testBackupS3 } from '../lib/api'
import { useAsync } from '../lib/useAsync'
import { REPO_URL } from '../lib/brand'
import {
  describeDuration,
  describeEncryption,
  describeRetention,
  destinationLabel,
  requestInFlight,
  runSummary,
} from '../lib/backups'
import { Badge, Button, Card, Spinner } from '../components/primitives'
import { Alert, CopyCommand, KeyValueList, Section } from '../components/patterns'
import { formatBytes, formatRelativeTime } from '../lib/format'
import { BackupSettings } from './BackupSettings'
import './BackupsCard.css'

const SETUP_COMMAND = 'docker compose up -d'
const OPT_OUT_LINE = 'BACKUP_REPLICAS=0'
const DOCS_URL = `${REPO_URL}/blob/main/docs/backup-restore.md`

function errMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message
  return e instanceof Error ? e.message : 'Request failed'
}

function when(iso: string | null | undefined) {
  if (!iso) return null
  return (
    <span className="wb-kv-note" title={new Date(iso).toLocaleString()}>
      {formatRelativeTime(iso)}
    </span>
  )
}

export function BackupsCard({ onChanged, title = 'Backups' }: { onChanged?: () => void; title?: string }) {
  const q = useAsync(getAdminBackups, [])
  const [busy, setBusy] = React.useState<'backup' | 'test_s3' | null>(null)
  const [editing, setEditing] = React.useState(false)
  const [actionError, setActionError] = React.useState<string | null>(null)
  const d = q.data
  const inflight = busy !== null || (d ? requestInFlight(d) : false)

  // While a request is open, poll until the backup service finishes it.
  const refetch = q.refetch
  const wasInflight = React.useRef(false)
  React.useEffect(() => {
    if (!inflight) {
      if (wasInflight.current) onChanged?.()
      wasInflight.current = false
      return
    }
    wasInflight.current = true
    const t = window.setInterval(refetch, 2500)
    return () => window.clearInterval(t)
  }, [inflight, refetch, onChanged])

  const start = async (kind: 'backup' | 'test_s3') => {
    setBusy(kind)
    setActionError(null)
    try {
      await (kind === 'backup' ? runBackupNow() : testBackupS3())
      refetch()
    } catch (e) {
      setActionError(errMessage(e))
    } finally {
      setBusy(null)
    }
  }

  const agent = d?.agent ?? null
  const cfg = agent?.config ?? {}
  const hasS3 = (cfg.destinations ?? []).some((x) => x.kind === 's3')
  const canAct = !!agent?.running && !inflight
  const enc = describeEncryption(cfg.encryption)

  const actions = (
    <>
      <Button variant={editing ? 'primary' : 'secondary'} size="sm" aria-expanded={editing} onClick={() => setEditing(!editing)}>
        {editing ? 'Close settings' : 'Change settings'}
      </Button>
      {hasS3 && !editing && (
        <Button
          variant="secondary"
          size="sm"
          disabled={!canAct}
          loading={busy === 'test_s3' || (inflight && d?.request?.kind === 'test_s3')}
          onClick={() => void start('test_s3')}
        >
          Test S3 connection
        </Button>
      )}
      <Button
        size="sm"
        disabled={!canAct}
        loading={busy === 'backup' || (inflight && d?.request?.kind === 'backup')}
        onClick={() => void start('backup')}
      >
        Back up now
      </Button>
    </>
  )

  return (
    <Section
      title={title}
      description="Every night the server backs up its database to this machine's disk, and optionally to an S3-compatible bucket."
      actions={d ? actions : undefined}
    >
      {q.loading && !d ? (
        <div className="wb-page-loading">
          <Spinner /> Loading…
        </div>
      ) : q.error ? (
        <Alert tone="danger" title="Couldn’t load backup status">
          {q.error.message}
        </Alert>
      ) : d ? (
        <div className="wb-bk">
          {!agent && (
            <Alert
              tone="warning"
              title="The backup service has not started yet"
              action={<CopyCommand command={SETUP_COMMAND} />}
            >
              Backups are part of the normal install. On the server, in the folder with <code>docker-compose.yml</code>,
              run the command shown here: it starts the backup service next to the server, and the first backup runs right
              after it starts.{' '}
              <a href={DOCS_URL} target="_blank" rel="noreferrer">
                Read the guide
              </a>
              .
            </Alert>
          )}
          {agent && !agent.running && (
            <Alert
              tone="danger"
              title="The backup service is not running"
              action={<CopyCommand command={SETUP_COMMAND} />}
            >
              It last reported {formatRelativeTime(agent.heartbeat_at)}. Scheduled backups and the buttons above are
              unavailable until it is started again.
            </Alert>
          )}
          {agent && cfg.encryption === 'none' && (
            <Alert tone="info" title="Backups are not encrypted yet">
              That is fine while they stay on this server (the database itself is not encrypted on disk either). Before
              you copy backups anywhere else or turn on S3, press <em>Change settings</em> and{' '}
              <em>Generate key pair</em> under Encryption, and keep the private key somewhere safe.
            </Alert>
          )}
          <Alert tone="info" title="Where backups are stored">
            Local copies go to the <code>backups</code> folder next to <code>docker-compose.yml</code> on the server
            (<code>BACKUP_LOCAL_PATH</code> in <code>.env</code> moves it; inside the container it is <code>/backups</code>).
            Files are named by date and end in <code>.age</code> when encrypted; by default the newest 7 daily, 4 weekly
            and 6 monthly are kept. S3 copies go to the bucket you configure under Settings. To turn the backup service
            off, put <code>{OPT_OUT_LINE}</code> in <code>.env</code> and run <code>docker compose up -d</code> again.
          </Alert>
          {actionError && (
            <Alert tone="danger" title="Couldn’t queue the request">
              {actionError}
            </Alert>
          )}
          {d.request && (inflight || d.request.finished_at) && Date.now() - Date.parse(d.request.requested_at) < 6 * 3600_000 && (
            <Alert
              tone={inflight ? 'info' : d.request.status === 'done' ? 'success' : 'danger'}
              title={
                (d.request.kind === 'backup' ? 'Back up now' : 'S3 connection test') +
                (inflight ? ' in progress…' : d.request.status === 'done' ? ' finished' : ' failed')
              }
            >
              {d.request.message ?? 'Waiting for the backup service to pick this up (it checks every few seconds).'}
            </Alert>
          )}
          {d.failing.map((f) => (
            <Alert key={f.destination} tone="danger" title={`Last backup to ${destinationLabel(f.destination)} failed`}>
              {f.error ?? 'No error was recorded.'} <span className="wb-kv-note">{formatRelativeTime(f.at)}</span>
            </Alert>
          ))}

          {editing && <BackupSettings onChanged={q.refetch} />}

          <Card>
            <KeyValueList
              label="Backup status"
              items={[
                {
                  label: 'Service',
                  value: agent ? (
                    <>
                      <Badge tone={agent.running ? 'green' : 'red'} dot>
                        {agent.running ? 'Running' : 'Not running'}
                      </Badge>
                      {agent.version && <span className="wb-kv-note wb-bk-mono">{agent.version.slice(0, 7)}</span>}
                    </>
                  ) : (
                    <Badge tone="grey">Not set up</Badge>
                  ),
                },
                {
                  label: 'Destinations',
                  value:
                    (cfg.destinations ?? []).length > 0 ? (
                      <ul className="wb-bk-dests">
                        {(cfg.destinations ?? []).map((x) => (
                          <li key={x.kind + x.target}>
                            <Badge tone={x.kind === 's3' ? 'purple' : 'neutral'}>{destinationLabel(x.kind)}</Badge>
                            <span className="wb-bk-target">{x.target}</span>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <span className="wb-kv-note">{agent ? 'None: turn on Local disk or S3 under Change settings' : 'Waiting for the backup service'}</span>
                    ),
                },
                { label: 'Encryption', value: agent ? <Badge tone={enc.tone}>{enc.text}</Badge> : <span className="wb-kv-note">—</span> },
                {
                  label: 'Last success',
                  value: d.last_success ? (
                    <>
                      <Badge tone={d.stale_after_hours && Date.now() - Date.parse(d.last_success.at) > d.stale_after_hours * 3600_000 ? 'orange' : 'green'} dot>
                        {destinationLabel(d.last_success.destination)}
                      </Badge>
                      {when(d.last_success.at)}
                      <span className="wb-kv-note">
                        {formatBytes(d.last_success.size_bytes)}
                        {d.last_success.duration_ms != null ? ` · ${describeDuration(d.last_success.duration_ms)}` : ''}
                      </span>
                    </>
                  ) : (
                    <Badge tone="red" dot>
                      None recorded
                    </Badge>
                  ),
                },
                {
                  label: 'Next scheduled run',
                  value: agent?.next_run_at ? (
                    <>
                      <span title={new Date(agent.next_run_at).toLocaleString()}>{new Date(agent.next_run_at).toLocaleString()}</span>
                      {cfg.schedule && (
                        <span className="wb-kv-note wb-bk-mono">
                          {cfg.schedule} · {cfg.timezone}
                        </span>
                      )}
                    </>
                  ) : (
                    <span className="wb-kv-note">—</span>
                  ),
                },
                { label: 'Retention', value: agent ? describeRetention(cfg.retention) : <span className="wb-kv-note">—</span> },
                {
                  label: 'Alert after',
                  value: <span className="wb-kv-note">{d.stale_after_hours} h without a successful backup</span>,
                },
              ]}
            />
          </Card>

          {d.recent.length > 0 && (
            <Card padded={false}>
              <ul className="wb-bk-runs" aria-label="Recent backup runs">
                {d.recent.map((r, i) => (
                  <li key={`${r.at}-${i}`} className="wb-bk-run">
                    <Badge tone={r.status === 'success' ? 'green' : 'red'}>{r.status === 'success' ? 'ok' : 'failed'}</Badge>
                    <span className="wb-bk-run-text">
                      {runSummary(r, formatBytes)}
                      {r.status === 'failed' && r.error && <span className="wb-bk-run-err">{r.error}</span>}
                    </span>
                    <span className="wb-sys-log-time" title={new Date(r.at).toLocaleString()}>
                      {formatRelativeTime(r.at)}
                    </span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </div>
      ) : null}
    </Section>
  )
}
