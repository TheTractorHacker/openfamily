// TypeScript types for the Orbitly live map.
//
// Mirrors the Flutter app's models (app/lib/models/member.dart) so the web
// panel derives status/movement from the same raw backend fields the app uses.

/** A geographic position. `lon` (not `lng`) matches the backend's field name. */
export interface LatLng {
  lat: number;
  lon: number;
}

/**
 * Health/accuracy state of a member's location, mapped to the colored status
 * ring on their avatar bubble and list row.
 *
 *  - normal   → green  (real-time, accurate)
 *  - warning  → orange (low battery < 15%)
 *  - gpsIssue → purple (accuracy > 100m)
 *  - stopped  → grey   (updates stopped / stale > 10min / never reported)
 *  - error    → red    (location error — present for parity, not derived by the
 *                       mapper, matching app/lib/services/member_mapper.dart)
 */
export type MemberStatus =
  | "normal"
  | "warning"
  | "gpsIssue"
  | "stopped"
  | "error";

/**
 * What a member is currently doing, shown as a small movement badge.
 *
 * The backend's free-form `motion_state` is reduced to `car` / `bike` / `none`
 * by `movementFrom` (see status.ts), exactly as the app's mapper does. The
 * richer variants (boat/plane/home/…) are kept for parity with the app's enum
 * so a future richer derivation can light them up without a type change.
 */
export type MovementType =
  | "car"
  | "bike"
  | "walking"
  | "running"
  | "boat"
  | "plane"
  | "home"
  | "work"
  | "gym"
  | "star"
  | "none";

/** Raw backend location fields (shared by member snapshots and live frames). */
export interface LocationFields {
  lat?: number | null;
  lon?: number | null;
  /** ISO-8601 string, or Unix seconds/milliseconds. */
  ts?: number | string | null;
  battery_pct?: number | null;
  /** Meters per second; converted to mph for display. */
  speed_mps?: number | null;
  /** Free-form movement string from the device. */
  motion_state?: string | null;
  /** Reported GPS accuracy in meters. */
  accuracy_meters?: number | null;
  /**
   * Freshest device heartbeat/ingest time across the member's devices
   * (ISO-8601 or Unix seconds/ms). Newer than `ts` when the member is
   * stationary and only heartbeats arrive.
   */
  last_seen_at?: number | string | null;
}

/**
 * A member row from `GET /api/admin/members` — every member across families,
 * each carrying `family_id` / `family_name` and the raw location fields.
 */
export interface RawMember extends LocationFields {
  id: string;
  name?: string;
  family_id?: string;
  family_name?: string;
  /** Avatar metadata; image bytes remain available only through an authenticated request. */
  has_avatar?: boolean;
  avatar_updated_at?: string | null;
  /** Durable revision that changes on every avatar upload or removal. */
  avatar_version?: number;
  avatar_url?: string | null;
}

/** A family/circle from `GET /api/admin/families`. */
export interface Group {
  id: string;
  name: string;
  created_at?: string;
  member_count?: number;
}

/**
 * A saved place (Home/School/Work/…) from `GET /api/admin/places`, tagged with
 * its owning family so the platform-admin map can draw pins across all families.
 */
export interface Place {
  id: string;
  familyId: string;
  familyName: string;
  name: string;
  /** Free-form place type: "home" | "school" | "work" | "other" (lowercased). */
  type: string;
  lat: number;
  lon: number;
  radiusMeters?: number | null;
  address: string;
}

/**
 * A fully-derived member rendered on the map and in the list panel.
 *
 * `position`/`lastSeen` are null when the member has never reported a location;
 * such members are shown in the list (grey "stopped") but have no map bubble,
 * matching the app.
 */
export interface Member {
  id: string;
  name: string;
  familyId: string;
  familyName: string;
  /** Group accent color (the initials-avatar fill + group dot). */
  avatarColor: string;
  /** Per-member identity color — the ring around the bubble, distinct per member. */
  memberColor: string;
  position: LatLng | null;
  status: MemberStatus;
  /** Battery percentage 0–100 (0 = unknown). */
  batteryPercent: number;
  movement: MovementType;
  /** Speed in mph, only meaningful when movement is "car". */
  speedMph: number | null;
  /** Epoch milliseconds (UTC) of the last report, or null if never. */
  lastSeen: number | null;
  /** Human-readable current place / activity label. */
  address: string;
  /** Avatar metadata from the member snapshot or live avatar frame. */
  hasAvatar?: boolean;
  avatarUpdatedAt?: string | null;
  /** Durable server-side avatar revision used for ordering and cache keys. */
  avatarVersion: number;
  /** A short-lived object URL created from an authenticated avatar response. */
  avatarUrl?: string | null;
}

/** A WebSocket frame on `/ws/stream`. */
export type StreamFrame =
  | { type: "members"; members: RawMember[] }
  | ({ type: "location"; user_id: string } & LocationFields)
  | {
      /** Liveness announcement without a position change (heartbeat/dedup). */
      type: "presence";
      user_id: string;
      ts?: number | string | null;
      battery_pct?: number | null;
    }
  | {
      type: "avatar";
      user_id: string;
      has_avatar: boolean;
      avatar_updated_at?: string | null;
      avatar_version?: number;
    }
  | { type: string; [k: string]: unknown };
