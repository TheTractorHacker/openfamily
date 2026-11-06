// Places page — platform-wide place/geofence editor. Click the map to drop a
// new place, drag its pin, resize the radius, rename or delete. Every place in
// every family is listed; saving goes through /api/admin/places.

import React from 'react'
import L from 'leaflet'
import { Circle, MapContainer, Marker, useMap, useMapEvents } from 'react-leaflet'
import {
  ApiError,
  createAdminPlace,
  deleteAdminPlace,
  listAdminCircles,
  listAdminPlaces,
  listFamilies,
  updateAdminPlace,
} from '../lib/api'
import { isAccessDenied, useAsync } from '../lib/useAsync'
import { AccessDenied, Badge, Button, EmptyState, ErrorState, Spinner } from '../components/primitives'
import { PageHeader } from '../components/patterns'
import { BaseMapLayer } from '../map/BaseMapLayer'
import type { AdminPlace } from '../lib/types'
import './pages.css'
import './PlacesPage.css'

const MIN_RADIUS = 76
const MAX_RADIUS = 3219
const TYPES = ['home', 'school', 'work', 'gym', 'custom'] as const

interface Draft {
  id: string | null // null = not saved yet
  familyId: string
  name: string
  type: string
  lat: number
  lon: number
  radius: number
  address: string
  circleId: string // '' = whole family
}

const pinIcon = L.divIcon({
  className: 'wb-place-pin',
  html: '<span></span>',
  iconSize: [22, 22],
  iconAnchor: [11, 11],
})

function toDraft(p: AdminPlace): Draft {
  return {
    id: p.id,
    familyId: p.family_id,
    name: p.name,
    type: p.type,
    lat: p.lat,
    lon: p.lon,
    radius: Math.round(p.radius_meters ?? 150),
    address: p.address ?? '',
    circleId: p.circle_id ?? '',
  }
}

function formatRadius(m: number): string {
  const ft = Math.round(m * 3.28084)
  return `${Math.round(m)} m (${ft.toLocaleString()} ft)`
}

function errorText(e: unknown): string {
  return e instanceof ApiError || e instanceof Error ? e.message : 'Request failed'
}

function ClickCatcher({ active, onPick }: { active: boolean; onPick: (lat: number, lon: number) => void }) {
  useMapEvents({
    click(e) {
      if (active) onPick(e.latlng.lat, e.latlng.lng)
    },
  })
  return null
}

function Fly({ target }: { target: { lat: number; lon: number; key: string } | null }) {
  const map = useMap()
  React.useEffect(() => {
    if (target) map.setView([target.lat, target.lon], Math.max(map.getZoom(), 15), { animate: true })
    // Only when the key (selection) changes, not on every drag.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target?.key])
  return null
}

export function PlacesPage() {
  const placesQ = useAsync(listAdminPlaces, [])
  const familiesQ = useAsync(listFamilies, [])
  const circlesQ = useAsync(listAdminCircles, [])
  const [draft, setDraft] = React.useState<Draft | null>(null)
  const [adding, setAdding] = React.useState(false)
  const [filterFamily, setFilterFamily] = React.useState('')
  const [busy, setBusy] = React.useState<'save' | 'delete' | null>(null)
  const [message, setMessage] = React.useState<{ tone: 'success' | 'error'; text: string } | null>(null)
  const [fly, setFly] = React.useState<{ lat: number; lon: number; key: string } | null>(null)

  const places = placesQ.data ?? []
  const families = familiesQ.data ?? []
  // Only circles that are still live can be chosen; the place's current one is
  // always kept so editing never silently changes who sees it.
  const circleOptions = (circlesQ.data ?? []).filter(
    (c) =>
      c.id === draft?.circleId ||
      (!c.family_backed && (c.status === 'permanent' || c.status === 'active')),
  )

  if (isAccessDenied(placesQ.error)) {
    return (
      <div className="wb-page">
        <AccessDenied />
      </div>
    )
  }
  if ((placesQ.loading && !placesQ.data) || (familiesQ.loading && !familiesQ.data)) {
    return (
      <div className="wb-page">
        <div className="wb-page-loading">
          <Spinner /> Loading places…
        </div>
      </div>
    )
  }
  if (placesQ.error || familiesQ.error) {
    return (
      <div className="wb-page">
        <ErrorState
          title="Couldn’t load places"
          description={placesQ.error?.message ?? familiesQ.error?.message}
          onRetry={() => {
            placesQ.refetch()
            familiesQ.refetch()
          }}
        />
      </div>
    )
  }

  const visible = filterFamily ? places.filter((p) => p.family_id === filterFamily) : places
  const center: [number, number] = visible[0] ? [visible[0].lat, visible[0].lon] : [39.5, -98.35]

  const select = (p: AdminPlace) => {
    setAdding(false)
    setMessage(null)
    setDraft(toDraft(p))
    setFly({ lat: p.lat, lon: p.lon, key: p.id })
  }

  const startAdd = () => {
    setDraft(null)
    setMessage(null)
    setAdding(true)
  }

  const onPick = (lat: number, lon: number) => {
    setAdding(false)
    setDraft({
      id: null,
      familyId: filterFamily || families[0]?.id || '',
      name: '',
      type: 'custom',
      lat,
      lon,
      radius: 150,
      address: '',
      circleId: '',
    })
  }

  const patch = (changes: Partial<Draft>) => setDraft((d) => (d ? { ...d, ...changes } : d))

  const save = async () => {
    if (!draft) return
    if (!draft.name.trim()) {
      setMessage({ tone: 'error', text: 'Give the place a name.' })
      return
    }
    if (!draft.familyId) {
      setMessage({ tone: 'error', text: 'Pick a family for this place.' })
      return
    }
    setBusy('save')
    setMessage(null)
    try {
      const body = {
        name: draft.name.trim(),
        type: draft.type,
        lat: draft.lat,
        lon: draft.lon,
        radius_meters: draft.radius,
        address: draft.address,
        circle_id: draft.circleId || null,
      }
      const saved = draft.id
        ? await updateAdminPlace(draft.id, body)
        : await createAdminPlace({ ...body, family_id: draft.familyId })
      placesQ.refetch()
      setDraft(toDraft(saved))
      setMessage({ tone: 'success', text: draft.id ? 'Place saved.' : 'Place created.' })
    } catch (e) {
      setMessage({ tone: 'error', text: errorText(e) })
    } finally {
      setBusy(null)
    }
  }

  const remove = async () => {
    if (!draft?.id) return
    if (!window.confirm(`Delete “${draft.name}”? Its arrival and departure alerts stop.`)) return
    setBusy('delete')
    setMessage(null)
    try {
      await deleteAdminPlace(draft.id)
      setDraft(null)
      placesQ.refetch()
      setMessage({ tone: 'success', text: 'Place deleted.' })
    } catch (e) {
      setMessage({ tone: 'error', text: errorText(e) })
    } finally {
      setBusy(null)
    }
  }

  const familyName = (id: string) => families.find((f) => f.id === id)?.name ?? ''

  return (
    <div className="wb-places">
      <PageHeader
        title="Places"
        subtitle="Add, move, resize and remove places for any family."
        actions={
          <>
        <label className="wb-field" htmlFor="places-family">
          <span className="wb-label">Family</span>
          <select
            id="places-family"
            className="wb-select"
            value={filterFamily}
            onChange={(e) => setFilterFamily(e.target.value)}
          >
            <option value="">All families</option>
            {families.map((f) => (
              <option key={f.id} value={f.id}>
                {f.name}
              </option>
            ))}
          </select>
        </label>
        <Button variant={adding ? 'secondary' : 'primary'} onClick={adding ? () => setAdding(false) : startAdd}>
          {adding ? 'Cancel' : 'Add place'}
        </Button>
          </>
        }
      />

      <div className="wb-places-body">
        <div className="wb-places-map" aria-label="Places map">
          <MapContainer
            className={`wb-places-leaflet${adding ? ' is-adding' : ''}`}
            center={center}
            zoom={visible.length ? 11 : 4}
            minZoom={3}
            scrollWheelZoom
          >
            <BaseMapLayer />
            <ClickCatcher active={adding} onPick={onPick} />
            <Fly target={fly} />
            {visible
              .filter((p) => p.id !== draft?.id && p.radius_meters)
              .map((p) => (
                <Circle
                  key={p.id}
                  center={[p.lat, p.lon]}
                  radius={p.radius_meters ?? 0}
                  pathOptions={{ color: '#7c3aed', weight: 1.5, fillOpacity: 0.08 }}
                  eventHandlers={{ click: () => select(p) }}
                />
              ))}
            {draft && (
              <>
                <Circle
                  center={[draft.lat, draft.lon]}
                  radius={draft.radius}
                  pathOptions={{ color: '#7c3aed', weight: 2.5, fillOpacity: 0.18 }}
                />
                <Marker
                  position={[draft.lat, draft.lon]}
                  icon={pinIcon}
                  draggable
                  eventHandlers={{
                    dragend(e) {
                      const ll = (e.target as L.Marker).getLatLng()
                      patch({ lat: ll.lat, lon: ll.lng })
                    },
                  }}
                />
              </>
            )}
          </MapContainer>
          {adding && <div className="wb-places-hint">Click the map where the new place should go</div>}
        </div>

        <aside className="wb-places-side">
          {draft ? (
            <form
              className="wb-places-editor"
              onSubmit={(e) => {
                e.preventDefault()
                void save()
              }}
            >
              <h2 className="wb-places-editor-title">{draft.id ? 'Edit place' : 'New place'}</h2>
              <label className="wb-field" htmlFor="place-name">
                <span className="wb-label">Name</span>
                <input
                  id="place-name"
                  className="wb-input"
                  value={draft.name}
                  maxLength={100}
                  onChange={(e) => patch({ name: e.target.value })}
                  autoFocus
                />
              </label>
              {draft.id ? (
                <div className="wb-field">
                  <span className="wb-label">Family</span>
                  <Badge tone="purple">{familyName(draft.familyId) || 'Family'}</Badge>
                </div>
              ) : (
                <label className="wb-field" htmlFor="place-family">
                  <span className="wb-label">Family</span>
                  <select
                    id="place-family"
                    className="wb-select"
                    value={draft.familyId}
                    onChange={(e) => patch({ familyId: e.target.value })}
                  >
                    {families.map((f) => (
                      <option key={f.id} value={f.id}>
                        {f.name}
                      </option>
                    ))}
                  </select>
                </label>
              )}
              <label className="wb-field" htmlFor="place-circle">
                <span className="wb-label">Share with</span>
                <select
                  id="place-circle"
                  className="wb-select"
                  value={draft.circleId}
                  onChange={(e) => patch({ circleId: e.target.value })}
                >
                  <option value="">Whole family</option>
                  {circleOptions.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
                <span className="wb-help">
                  A circle place is visible to, and alerts, only that circle’s members.
                </span>
              </label>
              <label className="wb-field" htmlFor="place-type">
                <span className="wb-label">Type</span>
                <select
                  id="place-type"
                  className="wb-select"
                  value={draft.type}
                  onChange={(e) => patch({ type: e.target.value })}
                >
                  {TYPES.map((t) => (
                    <option key={t} value={t}>
                      {t[0].toUpperCase() + t.slice(1)}
                    </option>
                  ))}
                </select>
              </label>
              <label className="wb-field" htmlFor="place-radius">
                <span className="wb-label">Radius — {formatRadius(draft.radius)}</span>
                <input
                  id="place-radius"
                  type="range"
                  min={MIN_RADIUS}
                  max={MAX_RADIUS}
                  step={1}
                  value={draft.radius}
                  onChange={(e) => patch({ radius: Number(e.target.value) })}
                />
              </label>
              <label className="wb-field" htmlFor="place-address">
                <span className="wb-label">Address (optional)</span>
                <input
                  id="place-address"
                  className="wb-input"
                  value={draft.address}
                  maxLength={500}
                  onChange={(e) => patch({ address: e.target.value })}
                />
              </label>
              <p className="wb-help">
                {draft.lat.toFixed(5)}, {draft.lon.toFixed(5)} — drag the pin to move it.
              </p>
              {message && (
                <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
                  {message.text}
                </p>
              )}
              <div className="wb-row">
                <Button type="submit" loading={busy === 'save'} disabled={busy !== null}>
                  {draft.id ? 'Save' : 'Create place'}
                </Button>
                {draft.id && (
                  <Button
                    type="button"
                    variant="danger"
                    loading={busy === 'delete'}
                    disabled={busy !== null}
                    onClick={() => void remove()}
                  >
                    Delete
                  </Button>
                )}
                <Button type="button" variant="ghost" onClick={() => setDraft(null)} disabled={busy !== null}>
                  Close
                </Button>
              </div>
            </form>
          ) : (
            <>
              {message && (
                <p className={message.tone === 'error' ? 'wb-error-text' : 'wb-help'} role="status">
                  {message.text}
                </p>
              )}
              {visible.length === 0 ? (
                <EmptyState
                  title="No places yet"
                  description="Use “Add place”, then click the map to drop one."
                />
              ) : (
                <ul className="wb-places-list">
                  {visible.map((p) => (
                    <li key={p.id}>
                      <button type="button" className="wb-places-item" onClick={() => select(p)}>
                        <span className="wb-places-item-name">{p.name}</span>
                        <span className="wb-places-item-sub">
                          {p.family_name} · {p.type}
                          {p.circle_name ? ` · ${p.circle_name}` : ''}
                          {p.radius_meters ? ` · ${Math.round(p.radius_meters)} m` : ''}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}
        </aside>
      </div>
    </div>
  )
}
