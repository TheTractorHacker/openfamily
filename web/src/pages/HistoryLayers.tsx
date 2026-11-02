// History extras: timeline playback and a density heatmap. The pure helpers
// (interpolation, grid bucketing) are exported for tests; the map layers must
// render inside a react-leaflet <MapContainer>.

import React from 'react'
import { CircleMarker, Polyline } from 'react-leaflet'
import type { HistoryTrailPoint } from '../lib/types'

export const PLAY_COLOR = '#7c3aed'

/** Playback speeds: minutes of the member's day shown per real second. */
export const PLAY_SPEEDS = [1, 4, 16] as const
export type PlaySpeed = (typeof PLAY_SPEEDS)[number]
const BASE_MS_PER_SEC = 60_000 // 1x = one minute of trail per second

export interface Playhead {
  /** Trail index of the last point at or before the playhead. */
  index: number
  lat: number
  lon: number
  /** Playhead time as epoch milliseconds. */
  ts: number
}

/** Epoch ms for each trail point (NaN-safe: bad timestamps sort as 0). */
export function trailTimes(trail: HistoryTrailPoint[]): number[] {
  return trail.map((p) => {
    const t = new Date(p.ts).getTime()
    return Number.isFinite(t) ? t : 0
  })
}

/** Position on the trail at epoch ms [t], interpolated between fixes. */
export function playheadAt(trail: HistoryTrailPoint[], times: number[], t: number): Playhead | null {
  const n = trail.length
  if (n === 0) return null
  if (t <= times[0]) return { index: 0, lat: trail[0].lat, lon: trail[0].lon, ts: times[0] }
  if (t >= times[n - 1]) {
    return { index: n - 1, lat: trail[n - 1].lat, lon: trail[n - 1].lon, ts: times[n - 1] }
  }
  // Binary search for the last index with times[i] <= t.
  let lo = 0
  let hi = n - 1
  while (lo < hi - 1) {
    const mid = (lo + hi) >> 1
    if (times[mid] <= t) lo = mid
    else hi = mid
  }
  const span = times[hi] - times[lo]
  const f = span > 0 ? (t - times[lo]) / span : 0
  return {
    index: lo,
    lat: trail[lo].lat + (trail[hi].lat - trail[lo].lat) * f,
    lon: trail[lo].lon + (trail[hi].lon - trail[lo].lon) * f,
    ts: t,
  }
}

export interface Playback {
  playing: boolean
  speed: PlaySpeed
  /** 0..1 position along the day's trail in time. */
  progress: number
  head: Playhead | null
  start: number
  end: number
  toggle: () => void
  setSpeed: (s: PlaySpeed) => void
  seek: (progress: number) => void
}

/** Drives a playhead along [trail] with requestAnimationFrame. */
export function usePlayback(trail: HistoryTrailPoint[]): Playback {
  const times = React.useMemo(() => trailTimes(trail), [trail])
  const start = times.length ? times[0] : 0
  const end = times.length ? times[times.length - 1] : 0
  const [playing, setPlaying] = React.useState(false)
  const [speed, setSpeed] = React.useState<PlaySpeed>(4)
  const [t, setT] = React.useState(start)
  const speedRef = React.useRef(speed)
  speedRef.current = speed
  const tRef = React.useRef(t)
  tRef.current = t

  React.useEffect(() => {
    if (!playing) return
    let raf = 0
    let last = performance.now()
    const tick = (now: number) => {
      const dt = now - last
      last = now
      const next = tRef.current + (dt / 1000) * BASE_MS_PER_SEC * speedRef.current
      if (next >= end) {
        tRef.current = end
        setT(end)
        setPlaying(false)
        return
      }
      tRef.current = next
      setT(next)
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [playing, end])

  const head = React.useMemo(() => playheadAt(trail, times, t), [trail, times, t])
  const progress = end > start ? Math.min(1, Math.max(0, (t - start) / (end - start))) : 0

  return {
    playing,
    speed,
    progress,
    head,
    start,
    end,
    toggle: () => {
      if (!playing && t >= end) setT(start) // replay from the top
      setPlaying((p) => !p)
    },
    setSpeed,
    seek: (p: number) => {
      setPlaying(false)
      setT(start + (end - start) * Math.min(1, Math.max(0, p)))
    },
  }
}

/** Marker plus the already-travelled part of the trail. */
export function PlaybackLayer({ trail, playback }: { trail: HistoryTrailPoint[]; playback: Playback }) {
  const { head } = playback
  if (!head || trail.length < 2) return null
  const travelled: [number, number][] = trail.slice(0, head.index + 1).map((p) => [p.lat, p.lon])
  travelled.push([head.lat, head.lon])
  return (
    <>
      {playback.progress > 0 && travelled.length >= 2 && (
        <Polyline positions={travelled} pathOptions={{ color: PLAY_COLOR, weight: 6, opacity: 1 }} />
      )}
      <CircleMarker
        center={[head.lat, head.lon]}
        radius={9}
        pathOptions={{ color: '#fff', weight: 3, fillColor: PLAY_COLOR, fillOpacity: 1 }}
      />
    </>
  )
}

export function PlaybackBar({ playback }: { playback: Playback }) {
  const clock = playback.head
    ? new Date(playback.head.ts).toLocaleString(undefined, {
        month: 'short',
        day: 'numeric',
        hour: 'numeric',
        minute: '2-digit',
      })
    : '—'
  return (
    <div className="wb-history-playbar" role="group" aria-label="Playback">
      <button
        type="button"
        className="wb-history-play"
        onClick={playback.toggle}
        aria-label={playback.playing ? 'Pause' : 'Play'}
      >
        {playback.playing ? '❚❚' : '▶'}
      </button>
      <input
        className="wb-history-scrub"
        type="range"
        min={0}
        max={1000}
        value={Math.round(playback.progress * 1000)}
        onChange={(e) => playback.seek(Number(e.target.value) / 1000)}
        aria-label="Position in the day"
      />
      <span className="wb-history-clock" aria-live="off">
        {clock}
      </span>
      <div className="wb-history-speeds" role="radiogroup" aria-label="Speed">
        {PLAY_SPEEDS.map((s) => (
          <button
            key={s}
            type="button"
            role="radio"
            aria-checked={playback.speed === s}
            className={`wb-history-speed${playback.speed === s ? ' is-on' : ''}`}
            onClick={() => playback.setSpeed(s)}
            title={`${s} minute${s === 1 ? '' : 's'} of the day per second`}
          >
            {s}×
          </button>
        ))}
      </div>
    </div>
  )
}

export interface HeatCell {
  lat: number
  lon: number
  count: number
}

/** ~55 m grid: coarse enough to merge a stay's jitter, fine enough for streets. */
const CELL_DEG = 0.0005

/** Buckets fixes into grid cells, densest first, capped for rendering. */
export function heatCells(points: { lat: number; lon: number }[], maxCells = 2500): HeatCell[] {
  const grid = new Map<string, HeatCell>()
  for (const p of points) {
    if (!Number.isFinite(p.lat) || !Number.isFinite(p.lon)) continue
    const gy = Math.round(p.lat / CELL_DEG)
    const gx = Math.round(p.lon / CELL_DEG)
    const key = `${gy}:${gx}`
    const cell = grid.get(key)
    if (cell) cell.count++
    else grid.set(key, { lat: gy * CELL_DEG, lon: gx * CELL_DEG, count: 1 })
  }
  return [...grid.values()].sort((a, b) => b.count - a.count).slice(0, maxCells)
}

/** Density as overlapping translucent discs; no plugin needed. */
export function HeatLayer({ points }: { points: { lat: number; lon: number }[] }) {
  const cells = React.useMemo(() => heatCells(points), [points])
  const max = cells.length ? cells[0].count : 1
  return (
    <>
      {cells.map((c) => {
        // log scale so one long stay doesn't wash out the rest of the map
        const w = Math.log1p(c.count) / Math.log1p(max)
        return (
          <CircleMarker
            key={`${c.lat}:${c.lon}`}
            center={[c.lat, c.lon]}
            radius={10 + 14 * w}
            pathOptions={{
              stroke: false,
              fillColor: w > 0.66 ? '#dc2626' : w > 0.33 ? '#f59e0b' : '#7c3aed',
              fillOpacity: 0.12 + 0.28 * w,
            }}
            interactive={false}
          />
        )
      })}
    </>
  )
}
