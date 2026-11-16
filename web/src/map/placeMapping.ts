// Maps the backend's snake_case place rows (GET /api/admin/places and
// GET /family/places) to the map's camelCase Place. The admin endpoint used to
// be cast straight to Place, so familyId / radiusMeters were undefined and every
// place vanished as soon as a group was picked in the switcher.

import type { Place } from "./types";

/** The fields of a backend place row the map reads. */
export interface ApiPlaceRow {
  id: string;
  family_id: string;
  family_name?: string | null;
  name: string;
  type?: string | null;
  lat: number;
  lon: number;
  radius_meters?: number | null;
  address?: string | null;
}

/** Converts one backend row; `familyName` fills in when the row has none (the family-scoped endpoint). */
export function placeFromApi(p: ApiPlaceRow, familyName = ""): Place {
  return {
    id: p.id,
    familyId: p.family_id,
    familyName: p.family_name || familyName,
    name: p.name ?? "",
    type: p.type || "other",
    lat: typeof p.lat === "number" ? p.lat : NaN,
    lon: typeof p.lon === "number" ? p.lon : NaN,
    radiusMeters: p.radius_meters ?? null,
    address: p.address ?? "",
  };
}

/** Maps a list response, dropping rows without a usable position so one bad row cannot break the map. */
export function placesFromApi(rows: unknown, familyName = ""): Place[] {
  if (!Array.isArray(rows)) return [];
  return (rows as ApiPlaceRow[])
    .map((r) => placeFromApi(r, familyName))
    .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lon));
}
