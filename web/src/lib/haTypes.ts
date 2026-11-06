// Home Assistant integration tokens (GET/POST/PATCH /integrations/ha/tokens).

export type HaScope = 'presence' | 'location' | 'places' | 'events' | 'driving'
export type HaEventKind =
  | 'arrival'
  | 'departure'
  | 'sos'
  | 'crash'
  | 'trip_start'
  | 'trip_end'
  | 'low_battery'

export interface HaToken {
  id: string
  name: string
  token_hint: string
  scopes: HaScope[]
  circle_ids: string[]
  created_at: string
  last_used_at: string | null
  webhook_configured: boolean
  webhook_url_masked: string
  webhook_allow_private: boolean
  webhook_events: HaEventKind[]
  webhook_failures: number
  last_delivery_at: string | null
  last_delivery_ok: boolean | null
  last_delivery_code: number | null
  last_delivery_error: string
  last_delivery_event: string
  /** Only in the response that created the token. */
  token?: string
  /** Only in the response that created the token or rotated the secret. */
  webhook_secret?: string
}

export interface HaCircleChoice {
  id: string
  name: string
  e2ee_mode?: string
}

export const HA_SCOPE_INFO: { id: HaScope; label: string; help: string }[] = [
  { id: 'presence', label: 'Presence', help: 'Home / away / place name, battery, speed, last seen.' },
  { id: 'location', label: 'GPS position', help: 'Latitude, longitude and accuracy (device tracker on the HA map).' },
  { id: 'places', label: 'Places', help: 'Your saved places, to use as zones.' },
  { id: 'events', label: 'Events', help: 'Arrivals, departures, SOS and crash alerts, low battery.' },
  { id: 'driving', label: 'Driving', help: 'Drives in the last 24 hours; trip start and end events.' },
]

export const HA_EVENT_INFO: { id: HaEventKind; label: string }[] = [
  { id: 'arrival', label: 'Arrival' },
  { id: 'departure', label: 'Departure' },
  { id: 'sos', label: 'SOS' },
  { id: 'crash', label: 'Possible crash' },
  { id: 'trip_start', label: 'Trip start' },
  { id: 'trip_end', label: 'Trip end' },
  { id: 'low_battery', label: 'Low battery' },
]
