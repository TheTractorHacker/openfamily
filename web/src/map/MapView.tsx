// MapView — the live map for the OpenFamily admin panel.
//
// A full-bleed Leaflet map (via react-leaflet) shows every group's members as
// avatar bubbles with colored status rings, clusters by on-screen proximity
// (collapsing into a count bubble that fans out on click), and stays live by
// applying `/ws/stream` `location` frames in real time and re-evaluating
// staleness on a timer. A group switcher filters the map; a side panel lists
// members and centers the map on a click.
//
// It can be driven two ways:
//   1. Shell-fed data: pass `groups` + `members` (the shell owns fetching/WS).
//   2. Self-sufficient: pass a `token` (and optionally `apiBase`) and it will
//      fetch + stream its own data.
//
// Self-sufficient mode honors a `scope`:
//   - 'admin'  → /api/admin/* endpoints + /api/admin/ws (server-wide view).
//   - 'family' → /family* endpoints + /ws/stream, i.e. exactly what the
//     mobile apps consume, scoped to the signed-in user's own circle.
//
// Status/movement derivation and clustering are ported 1:1 from the Flutter app
// (app/lib/services/member_mapper.dart, app/lib/utils/member_clustering.dart).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Map as LeafletMap } from "leaflet";
import {
  Circle,
  MapContainer,
  Marker,
  Popup,
  useMapEvents,
} from "react-leaflet";
import "./map.css";
import { BaseMapLayer } from "./BaseMapLayer";
import { AnimatedMarker } from "./AnimatedMarker";
import { clusterMembers, placeBubbles, type BubblePlacement, type Pt } from "./clustering";
import { clusterBubbleIcon, memberBubbleIcon } from "./memberBubble";
import { GroupSwitcher } from "./groupSwitcher";
import { MemberCard } from "./MemberCard";
import { MemberList } from "./memberList";
import { getAdminMemberAvatar, getFamilyMemberAvatar } from "../lib/api";
import type { FamilyPlace, MyFamily } from "../lib/types";
import { useMemberAvatarUrls } from "../lib/useMemberAvatarUrls";
import {
  applyLocationUpdate,
  applyPlaceAddress,
  applyPresenceUpdate,
  avatarVersionFrom,
  deriveMember,
  parseTs,
  refreshStaleness,
  STALE_AFTER_MS,
} from "./status";
import type { Group, LatLng, Member, Place, RawMember, StreamFrame } from "./types";
import { placeBubbleIcon } from "./placeBubble";

/** Default OSM tile URL — privacy-first, matching the app. Swap for a self-hosted server. */
export const DEFAULT_TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";

/** Radius (meters) of the translucent "approximate zone" circle for GPS-issue members. */
const APPROX_ZONE_RADIUS_M = 300;

/** Zoom the camera animates to when a cluster is expanded. */
const EXPAND_ZOOM = 16;

/** Zoom used when recentering on a single member from the list. */
const RECENTER_ZOOM = 15;

/** Per-group accent palette (each family gets a distinct color). */
const GROUP_PALETTE = [
  "#8fd400",
  "#e91e8c",
  "#0a84ff",
  "#34c759",
  "#ff9500",
  "#af52de",
  "#00c7be",
  "#ff2d55",
  "#5ac8fa",
  "#ffd60a",
];

/**
 * Per-member identity palette — the ring color that makes each member
 * distinguishable at a glance. Distinct hues, stable by member id, so a member
 * keeps the same color across renders and updates.
 *
 * Deliberately deeper/more saturated than GROUP_PALETTE so a member's identity
 * ring never reads as another family's accent color.
 */
const MEMBER_PALETTE = [
  "#7c3aed", // violet-600
  "#db2777", // pink-600
  "#2563eb", // blue-600
  "#059669", // emerald-600
  "#d97706", // amber-600
  "#9333ea", // purple-600
  "#0d9488", // teal-600
  "#e11d48", // rose-600
  "#0284c7", // sky-600
  "#ca8a04", // yellow-600
  "#ea580c", // orange-600
  "#7e22ce", // purple-700
  "#15803d", // green-700
  "#b45309", // amber-700
  "#1d4ed8", // blue-700
  "#b91c1c", // red-700
];

export interface MapViewProps {
  /**
   * Which API surface the map consumes in self-managed mode. 'admin' uses the
   * server-wide platform-admin endpoints; 'family' mirrors the mobile apps by
   * using the family-scoped endpoints for the signed-in user's own circle.
   */
  scope?: "admin" | "family";
  /** Families to show in the group switcher. Required when not self-fetching. */
  groups?: Group[];
  /** Pre-derived members (shell-fed mode). When omitted, `token` is used to fetch. */
  members?: Member[];
  /** Access token; when set (and `members` omitted) the view fetches + streams its own data. */
  token?: string;
  /** Base URL for the API + WebSocket. Defaults to the page origin. */
  apiBase?: string;
  /** Tile layer URL override (default: OpenStreetMap). */
  tileUrl?: string;
  /** Controlled active group id (`null` = all groups). */
  selectedGroupId?: string | null;
  /** Called when the active group changes. */
  onGroupChange?: (groupId: string | null) => void;
  /** Optional class on the outer wrapper. */
  className?: string;
  /** Initial map center [lat, lon]. */
  initialCenter?: [number, number];
  /** Initial map zoom. */
  initialZoom?: number;
}

/** Assigns each group a stable accent color (by sorted index). */
function assignGroupColors(groups: Group[]): Map<string, string> {
  const sorted = [...groups].sort((a, b) => a.id.localeCompare(b.id));
  const map = new Map<string, string>();
  sorted.forEach((g, i) => map.set(g.id, GROUP_PALETTE[i % GROUP_PALETTE.length]!));
  return map;
}

/** Assigns each member a stable identity color by hashing the id to a palette
 *  slot — so a member's color never shifts when other members are added/removed. */
function assignMemberColors(raws: RawMember[]): Map<string, string> {
  const map = new Map<string, string>();
  for (const r of raws) {
    const id = r.id ?? "";
    if (map.has(id)) continue;
    let h = 0;
    for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
    map.set(id, MEMBER_PALETTE[h % MEMBER_PALETTE.length]!);
  }
  return map;
}

/** Builds derived members from raw backend rows using the group + member color maps. */
function buildMembers(raws: RawMember[], colors: Map<string, string>, now: number): Member[] {
  const memberColors = assignMemberColors(raws);
  return raws.map((r) => {
    const fid = r.family_id ?? "";
    const fname = r.family_name ?? "Unknown";
    return deriveMember(
      r,
      fid,
      fname,
      colors.get(fid) ?? "#8fd400",
      memberColors.get(r.id ?? "") ?? "#8fd400",
      now,
    );
  });
}

/** Picks a base URL (defaults to the page origin, no trailing slash). */
function resolveBase(apiBase?: string): string {
  if (apiBase) return apiBase.replace(/\/+$/, "");
  if (typeof window !== "undefined") return window.location.origin;
  return "http://localhost:8080";
}

/** Whether this map is running against the portal's own API origin. */
function isSameOriginApi(apiBase?: string): boolean {
  if (typeof window === "undefined") return false;
  try {
    return new URL(resolveBase(apiBase), window.location.origin).origin === window.location.origin;
  } catch {
    return false;
  }
}

/** Converts an http(s) base URL to its ws(s) counterpart. */
function toWsBase(base: string): string {
  return base.replace(/^http/, "ws");
}

async function fetchJson<T>(url: string, token?: string): Promise<T> {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  return (await res.json()) as T;
}

/** Fetches private avatar bytes with the Authorization header, never in a URL. */
async function fetchBlob(url: string, token: string): Promise<Blob> {
  const res = await fetch(url, {
    headers: {
      Accept: "image/jpeg, image/png, image/*;q=0.8, */*;q=0.1",
      Authorization: `Bearer ${token}`,
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  return res.blob();
}

export function MapView(props: MapViewProps): JSX.Element {
  const {
    scope = "admin",
    groups: groupsProp,
    members: membersProp,
    token,
    apiBase,
    tileUrl = DEFAULT_TILE_URL,
    className,
    initialCenter = [37.7749, -122.4194],
    initialZoom = 13,
  } = props;

  // Self-managed mode = no shell-fed members (must have a token to fetch).
  const selfManaged = membersProp === undefined;

  // --- data state ---
  const [fetchedGroups, setFetchedGroups] = useState<Group[]>([]);
  const [fetchedMembers, setFetchedMembers] = useState<Member[]>([]);
  const [fetchedPlaces, setFetchedPlaces] = useState<Place[]>([]);
  const [loading, setLoading] = useState<boolean>(selfManaged);
  const [error, setError] = useState<string | null>(null);
  // Bumped to re-run the fetch effect in place (Retry) without a page reload.
  const [reloadKey, setReloadKey] = useState(0);

  const groups = groupsProp ?? fetchedGroups;
  const avatarSources = useMemo(
    () =>
      fetchedMembers.map((member) => ({
        id: member.id,
        hasAvatar: member.hasAvatar,
        avatarUpdatedAt: member.avatarUpdatedAt,
        avatarVersion: member.avatarVersion,
      })),
    [fetchedMembers],
  );
  const loadMemberAvatar = useCallback(
    (memberId: string) => {
      // The portal's normal same-origin route goes through the shared API
      // client, preserving its one-time 401 refresh/replay behavior. A custom
      // API base remains supported for embedded/standalone map consumers.
      if (isSameOriginApi(apiBase)) {
        return scope === "family"
          ? getFamilyMemberAvatar(memberId)
          : getAdminMemberAvatar(memberId);
      }
      if (!token) return Promise.reject(new Error("Missing access token"));
      const base = resolveBase(apiBase);
      const path =
        scope === "family"
          ? `/family/members/${encodeURIComponent(memberId)}/avatar`
          : `/api/admin/members/${encodeURIComponent(memberId)}/avatar`;
      return fetchBlob(`${base}${path}`, token);
    },
    [apiBase, token, scope],
  );
  const fetchedAvatarUrls = useMemberAvatarUrls(avatarSources, loadMemberAvatar, {
    enabled: selfManaged && Boolean(token),
    // Do not retain a browser object URL across a changed login or API origin.
    cacheKey: `${resolveBase(apiBase)}\u0000${token ?? ""}`,
  });
  const members = useMemo(() => {
    const base = !selfManaged
      ? membersProp ?? []
      : // Snapshot `avatar_url` values are intentionally ignored in
        // self-managed mode: member photos only come from the authenticated
        // byte endpoint.
        fetchedMembers.map((member) => ({
          ...member,
          avatarUrl: fetchedAvatarUrls[member.id] ?? undefined,
        }));
    // Overlay saved-place names (Home, Work, …) on stationary members so the
    // list agrees with the pins the map already draws.
    return base.map((m) => applyPlaceAddress(m, fetchedPlaces));
  }, [fetchedAvatarUrls, fetchedMembers, fetchedPlaces, membersProp, selfManaged]);

  // --- group color map (and a ref so WS handlers see the latest) ---
  const colorsById = useMemo(() => assignGroupColors(groups), [groups]);
  const colorsRef = useRef(colorsById);
  colorsRef.current = colorsById;

  // --- group filter (controlled or internal) ---
  const [groupFilter, setGroupFilter] = useState<string | null>(props.selectedGroupId ?? null);
  useEffect(() => {
    if (props.selectedGroupId !== undefined) setGroupFilter(props.selectedGroupId);
  }, [props.selectedGroupId]);
  const setGroup = useCallback(
    (id: string | null) => {
      setGroupFilter(id);
      props.onGroupChange?.(id);
    },
    [props],
  );

  // --- selection + clusters + camera ---
  const [selectedMemberId, setSelectedMemberId] = useState<string | null>(null);
  const [locationRequest, setLocationRequest] = useState<{
    memberId: string;
    sending: boolean;
    message: string | null;
  } | null>(null);
  const [expandedClusters, setExpandedClusters] = useState<Set<string>>(new Set());
  const [panelCollapsed, setPanelCollapsed] = useState(false);
  const [map, setMap] = useState<LeafletMap | null>(null);
  const [viewTick, setViewTick] = useState(0);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const prevZoomRef = useRef<number | null>(null);
  const didFitRef = useRef(false);

  // --- visible members for the current group filter ---
  const visibleMembers = useMemo(
    () => (groupFilter == null ? members : members.filter((m) => m.familyId === groupFilter)),
    [members, groupFilter],
  );

  // Shared requester used by both the member card button and the automatic
  // refresh of quiet members after load. The backend authorizes same-family
  // membership (and reports conflicts/unreachability), so this works from
  // either portal scope.
  const requestLocation = useCallback(
    async (memberId: string): Promise<{ ok: boolean; message: string }> => {
      if (!token) return { ok: false, message: "Not signed in." };
      const base = resolveBase(apiBase);
      try {
        const response = await fetch(
          `${base}/family/members/${encodeURIComponent(memberId)}/location-request`,
          {
            method: "POST",
            headers: { Authorization: `Bearer ${token}` },
          },
        );
        const data = (await response.json().catch(() => ({}))) as {
          status?: string;
          error?: string;
        };
        if (!response.ok) {
          let message: string;
          if (response.status === 409) {
            message =
              "This phone has no registered push connection. Open the app on the phone once to reconnect it.";
          } else if (response.status >= 500) {
            message = "Could not reach the phone right now. Try again shortly.";
          } else {
            message = data.error ?? `Request failed (${response.status})`;
          }
          return { ok: false, message };
        }
        const message =
          data.status === "cooldown"
            ? "A recent request is still cooling down."
            : data.status === "coalesced"
              ? "A location request is already in progress."
              : "Request sent. The map will update when the phone responds.";
        return { ok: true, message };
      } catch {
        return { ok: false, message: "Could not reach the server." };
      }
    },
    [apiBase, token],
  );

  const requestSelectedLocation = useCallback(async (): Promise<void> => {
    if (!selectedMemberId) return;
    setLocationRequest({ memberId: selectedMemberId, sending: true, message: "Requesting a fresh location…" });
    const result = await requestLocation(selectedMemberId);
    setLocationRequest({ memberId: selectedMemberId, sending: false, message: result.message });
  }, [requestLocation, selectedMemberId]);

  const requestMemberLocation = useCallback(
    (member: Member): void => {
      setLocationRequest({ memberId: member.id, sending: true, message: "Requesting a fresh location…" });
      void requestLocation(member.id).then((result) => {
        setLocationRequest({ memberId: member.id, sending: false, message: result.message });
      });
    },
    [requestLocation],
  );

  // --- visible places for the current group filter ---
  const visiblePlaces = useMemo(
    () => (groupFilter == null ? fetchedPlaces : fetchedPlaces.filter((p) => p.familyId === groupFilter)),
    [fetchedPlaces, groupFilter],
  );

  const countsById = useMemo(() => {
    const m = new Map<string, number>();
    for (const mem of members) m.set(mem.familyId, (m.get(mem.familyId) ?? 0) + 1);
    return m;
  }, [members]);

  /* ----------------------------- data fetching + WS ----------------------------- */
  useEffect(() => {
    if (!selfManaged || !token) return;
    let cancelled = false;
    let ws: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let retries = 0;
    const base = resolveBase(apiBase);

    const connect = (): void => {
      // 'admin' streams the platform-admin socket (live updates across ALL
      // families); 'family' streams the caller's own circle, matching /ws/stream
      // in the mobile apps. Frame shapes are identical.
      const streamPath = scope === "family" ? "/ws/stream" : "/api/admin/ws";
      const url = `${toWsBase(base)}${streamPath}`;
      try {
        // The access token is sent as the Sec-WebSocket-Protocol subprotocol,
        // matching the app's existing stream handshake.
        ws = new WebSocket(url, token);
      } catch {
        scheduleReconnect();
        return;
      }
      ws.onmessage = (ev) => {
        if (cancelled) return;
        let frame: StreamFrame;
        try {
          frame = JSON.parse(ev.data as string) as StreamFrame;
        } catch {
          return;
        }
        const now = Date.now();
        if (frame.type === "members") {
          const f = frame as Extract<StreamFrame, { type: "members" }>;
          setFetchedMembers(buildMembers(f.members, colorsRef.current, now));
        } else if (frame.type === "location") {
          const f = frame as Extract<StreamFrame, { type: "location" }>;
          setFetchedMembers((prev) =>
            prev.map((m) => (m.id === f.user_id ? applyLocationUpdate(m, f, now) : m)),
          );
        } else if (frame.type === "presence") {
          // Liveness without a position change (stationary dedup / heartbeat).
          const f = frame as Extract<StreamFrame, { type: "presence" }>;
          setFetchedMembers((prev) =>
            prev.map((m) => (m.id === f.user_id ? applyPresenceUpdate(m, f, now) : m)),
          );
        } else if (frame.type === "avatar") {
          const f = frame as Extract<StreamFrame, { type: "avatar" }>;
          const avatarVersion = avatarVersionFrom(f.avatar_version);
          setFetchedMembers((prev) =>
            prev.map((member) =>
              member.id === f.user_id && avatarVersion > member.avatarVersion
                ? {
                    ...member,
                    hasAvatar: f.has_avatar,
                    avatarUpdatedAt: f.avatar_updated_at ?? null,
                    avatarVersion,
                  }
                : member,
            ),
          );
        }
      };
      ws.onclose = () => {
        if (!cancelled) scheduleReconnect();
      };
      ws.onerror = () => {
        ws?.close();
      };
    };
    const scheduleReconnect = (): void => {
      if (cancelled || retries >= 8) return;
      retries += 1;
      reconnectTimer = setTimeout(connect, Math.min(4000 * retries, 20000));
    };

    async function load(): Promise<void> {
      setLoading(true);
      setError(null);
      try {
        let g: Group[];
        let raw: RawMember[];
        let places: Place[];
        if (scope === "family") {
          // App-parity surface: one group (the caller's own circle), its
          // members, and its shared places.
          const [fam, mems, famPlaces] = await Promise.all([
            fetchJson<MyFamily>(`${base}/family`, token),
            fetchJson<RawMember[]>(`${base}/family/members`, token),
            fetchJson<FamilyPlace[]>(`${base}/family/places`, token),
          ]);
          g = [{ id: fam.id, name: fam.name, created_at: fam.created_at }];
          raw = mems.map((m) => ({ ...m, family_id: fam.id, family_name: fam.name }));
          places = famPlaces.map((p) => ({
            id: p.id,
            familyId: p.family_id,
            familyName: fam.name,
            name: p.name,
            type: p.type,
            lat: p.lat,
            lon: p.lon,
            radiusMeters: p.radius_meters ?? null,
            address: p.address,
          }));
        } else {
          [g, raw, places] = await Promise.all([
            fetchJson<Group[]>(`${base}/api/admin/families`, token),
            fetchJson<RawMember[]>(`${base}/api/admin/members`, token),
            fetchJson<Place[]>(`${base}/api/admin/places`, token),
          ]);
        }
        if (cancelled) return;
        setFetchedGroups(g);
        const colors = assignGroupColors(g);
        colorsRef.current = colors;
        setFetchedMembers(buildMembers(raw, colors, Date.now()));
        setFetchedPlaces(places);
        setLoading(false);
        retries = 0;
        connect();

        // A viewer opening the map usually wants current positions, and the
        // snapshot can only show what the database holds. Ask quiet members'
        // phones (one or two of them, once per page load) for a fresh fix;
        // the server rate-limits each member to one attempt per watchdog
        // window, so this stays cheap even with many viewers. Failures are
        // silent here — the member card surfaces errors for manual requests.
        const quiet = raw
          .map((m) => ({
            id: m.id,
            seen: parseTs(m.last_seen_at ?? m.ts),
          }))
          .filter((m) => m.seen == null || Date.now() - m.seen > STALE_AFTER_MS)
          .slice(0, 2);
        for (const m of quiet) {
          void requestLocation(m.id);
        }
      } catch (e) {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : "Could not load families. Check your connection and try again.");
        setLoading(false);
      }
    }

    void load();
    return () => {
      cancelled = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      ws?.close();
    };
  }, [selfManaged, token, apiBase, scope, reloadKey, requestLocation]);

  /* ----------------------------- staleness timer ----------------------------- */
  useEffect(() => {
    if (!selfManaged) return;
    const id = setInterval(() => {
      const now = Date.now();
      setNowMs(now);
      setFetchedMembers((prev) => prev.map((m) => refreshStaleness(m, now)));
    }, 5000);
    return () => clearInterval(id);
  }, [selfManaged]);

  // Keep `nowMs` advancing even in shell-fed mode so list labels stay fresh.
  useEffect(() => {
    if (selfManaged) return;
    const id = setInterval(() => setNowMs(Date.now()), 5000);
    return () => clearInterval(id);
  }, [selfManaged]);

  /* --------------------- cluster prune (members moved apart) --------------------- */
  // Drops expanded-cluster ids that no longer correspond to a multi-member
  // cluster (their members moved apart). Ports _pruneExpandedClusters. This
  // runs on data changes only — NOT on zoom — so expanding a cluster (which
  // zooms in and separates the members on screen) does not immediately
  // re-collapse it.
  useEffect(() => {
    if (!map) return;
    setExpandedClusters((prevSet) => {
      if (prevSet.size === 0) return prevSet;
      const clusters = clusterMembers(
        visibleMembers,
        (m) => {
          const p = map.latLngToContainerPoint([m.position!.lat, m.position!.lon]);
          return { x: p.x, y: p.y } as Pt;
        },
      );
      const valid = new Set(clusters.filter((c) => c.members.length > 1).map((c) => c.id));
      const filtered = new Set([...prevSet].filter((id) => valid.has(id)));
      return filtered.size === prevSet.size ? prevSet : filtered;
    });
  }, [map, visibleMembers]);

  /* --------------------- collapse expanded clusters on zoom-out --------------------- */
  // On a user-initiated zoom-out (decrease > 0.5), collapse every expanded
  // cluster. Only acts on a zoom decrease, so the programmatic expand zoom-in
  // never re-collapses the cluster the user just opened. Ports the
  // _onCameraChanged zoom-out collapse from map_screen.dart.
  useEffect(() => {
    if (!map) return;
    const zoom = map.getZoom();
    const prev = prevZoomRef.current;
    prevZoomRef.current = zoom;
    if (prev != null && zoom < prev - 0.5) {
      setExpandedClusters((prevSet) => (prevSet.size === 0 ? prevSet : new Set()));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, viewTick]);

  /* ----------------------------- placements (clustering) ----------------------------- */
  const placements = useMemo<BubblePlacement[]>(() => {
    if (!map) return [];
    const toScreenPoint = (m: Member): Pt => {
      const p = map.latLngToContainerPoint([m.position!.lat, m.position!.lon]);
      return { x: p.x, y: p.y };
    };
    const toLatLng = (p: Pt): LatLng => {
      const ll = map.containerPointToLatLng([p.x, p.y]);
      return { lat: ll.lat, lon: ll.lng };
    };
    return placeBubbles(visibleMembers, toScreenPoint, toLatLng, {
      expandedClusterIds: expandedClusters,
    });
    // viewTick is a deliberate dependency so zoom changes re-cluster.
  }, [map, viewTick, visibleMembers, expandedClusters]);

  /* ----------------------------- GPS-issue "approximate zone" circles ----------------------------- */
  const gpsIssueMembers = useMemo(
    () => visibleMembers.filter((m) => m.status === "gpsIssue" && m.position != null),
    [visibleMembers],
  );

  /* ----------------------------- fit to members on first load ----------------------------- */
  useEffect(() => {
    if (!map || didFitRef.current) return;
    const positioned = visibleMembers.filter((m) => m.position != null);
    if (positioned.length === 0) return;
    didFitRef.current = true;
    if (positioned.length === 1) {
      map.setView([positioned[0]!.position!.lat, positioned[0]!.position!.lon], RECENTER_ZOOM);
    } else {
      const lats = positioned.map((m) => m.position!.lat);
      const lons = positioned.map((m) => m.position!.lon);
      const bounds: [[number, number], [number, number]] = [
        [Math.min(...lats), Math.min(...lons)],
        [Math.max(...lats), Math.max(...lons)],
      ];
      map.fitBounds(bounds, { padding: [80, 80] });
    }
  }, [map, visibleMembers]);

  /* ----------------------------- actions ----------------------------- */
  const recenterOn = useCallback(
    (member: Member) => {
      setSelectedMemberId(member.id);
      if (!map || !member.position) return;
      map.flyTo([member.position.lat, member.position.lon], Math.max(map.getZoom(), RECENTER_ZOOM), {
        duration: 0.6,
      });
    },
    [map],
  );

  const expandCluster = useCallback(
    (clusterId: string, centroid: LatLng) => {
      setExpandedClusters((prev) => new Set(prev).add(clusterId));
      map?.flyTo([centroid.lat, centroid.lon], EXPAND_ZOOM, { duration: 0.6 });
    },
    [map],
  );

  const handleMemberTap = useCallback((m: Member) => setSelectedMemberId(m.id), []);

  /* ----------------------------- render ----------------------------- */
  const panelTitle =
    groupFilter == null
      ? `All groups · ${visibleMembers.length}`
      : `${groups.find((g) => g.id === groupFilter)?.name ?? "Group"} · ${visibleMembers.length}`;

  const showOverlay =
    loading ||
    error != null ||
    (map != null && !loading && placements.length === 0 && visiblePlaces.length === 0);

  const selectedMember = selectedMemberId
    ? members.find((m) => m.id === selectedMemberId) ?? null
    : null;

  return (
    <div className={`wb-map ${className ?? ""}`}>
      <MapContainer
        center={initialCenter}
        zoom={initialZoom}
        minZoom={3}
        maxZoom={18}
        zoomControl
        scrollWheelZoom
        className="wb-leaflet"
        ref={(m) => setMap(m)}
      >
        <BaseMapLayer rasterUrl={tileUrl} />
        <ZoomWatcher onZoom={() => setViewTick((t) => t + 1)} />

        {/* GPS-issue approximate zones */}
        {gpsIssueMembers.map((m) => (
          <Circle
            key={`zone-${m.id}`}
            center={[m.position!.lat, m.position!.lon]}
            radius={APPROX_ZONE_RADIUS_M}
            pathOptions={{
              color: "#af52de",
              fillColor: "#af52de",
              fillOpacity: 0.12,
              opacity: 0.5,
              weight: 2,
            }}
          />
        ))}

        {/* Saved-place pins (Home/School/Work) */}
        {visiblePlaces.map((place) => (
          <Marker
            key={`place-${place.id}`}
            position={[place.lat, place.lon]}
            icon={placeBubbleIcon(place)}
          >
            <Popup>
              <div className="wb-place-popup">
                <strong>{place.name}</strong>
                <span className="wb-place-popup-family">{place.familyName}</span>
                {place.address ? <span className="wb-place-popup-addr">{place.address}</span> : null}
                {place.radiusMeters != null ? (
                  <span className="wb-place-popup-radius">{Math.round(place.radiusMeters)} m radius</span>
                ) : null}
              </div>
            </Popup>
          </Marker>
        ))}

        {/* Member + cluster bubbles */}
        {placements.map((p) =>
          p.isCluster ? (
            <Marker
              key={`c-${p.clusterId}`}
              position={[p.position.lat, p.position.lon]}
              icon={clusterBubbleIcon(p.clusterMembers)}
              eventHandlers={{ click: () => expandCluster(p.clusterId!, p.position) }}
            />
          ) : (
            <AnimatedMarker
              key={`m-${p.member!.id}`}
              position={[p.position.lat, p.position.lon]}
              icon={memberBubbleIcon(p.member!, selectedMemberId === p.member!.id)}
              onClick={() => handleMemberTap(p.member!)}
              zIndexOffset={selectedMemberId === p.member!.id ? 1000 : 0}
            />
          ),
        )}
      </MapContainer>

      <GroupSwitcher
        groups={groups}
        countsById={countsById}
        selectedId={groupFilter}
        onSelect={setGroup}
        colorsById={colorsById}
      />

      {!showOverlay && (
        <div className="wb-live-badge" aria-label="Live">
          <span className="wb-live-dot" />
          LIVE
        </div>
      )}

      <MemberList
        members={visibleMembers}
        selectedId={selectedMemberId}
        onSelect={recenterOn}
        collapsed={panelCollapsed}
        onToggleCollapsed={() => setPanelCollapsed((c) => !c)}
        title={panelTitle}
        nowMs={nowMs}
        onRequestLocation={selfManaged && token ? requestMemberLocation : undefined}
        requestingMemberId={locationRequest?.sending ? locationRequest.memberId : null}
      />

      {selectedMember && (
        <MemberCard
          member={selectedMember}
          nowMs={nowMs}
          onClose={() => setSelectedMemberId(null)}
          onRequestLocation={
            selfManaged && token ? requestSelectedLocation : undefined
          }
          requestingLocation={
            locationRequest?.memberId === selectedMember.id && locationRequest.sending
          }
          locationRequestStatus={
            locationRequest?.memberId === selectedMember.id ? locationRequest.message : null
          }
        />
      )}

      {showOverlay ? (
        <div className="wb-state wb-loading">
          {loading ? (
            <>
              <div className="wb-map-spinner" />
              <p className="wb-state-text">Loading live locations…</p>
            </>
          ) : error != null ? (
            <div className="wb-state-card">
              <span className="wb-state-icon">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                  <path d="M12 21s-7-5.5-7-11a7 7 0 0 1 14 0c0 5.5-7 11-7 11Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
                  <circle cx="12" cy="10" r="2.5" stroke="currentColor" strokeWidth="1.6" />
                </svg>
              </span>
              <span className="wb-state-title">Couldn’t load the map</span>
              <span className="wb-state-text">{error}</span>
              <button
                type="button"
                className="wb-state-retry"
                onClick={() => {
                  setError(null);
                  setLoading(true);
                  setReloadKey((k) => k + 1);
                }}
              >
                Retry
              </button>
            </div>
          ) : (
            <div className="wb-state-card">
              <span className="wb-state-icon" style={{ color: "var(--status-grey)" }}>
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                  <path d="M9 4 3 6.2v14L9 18l6 2.2 6-2.2v-14L15 6.2 9 4Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
                  <path d="M9 4v14m6-11.8V20" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
                </svg>
              </span>
              <span className="wb-state-title">
                {visibleMembers.length === 0 ? "No members to map yet" : "No locations reported yet"}
              </span>
              <span className="wb-state-text">
                {visibleMembers.length === 0
                  ? "When families have members reporting their location, they’ll appear here live."
                  : "Members are here, but none have reported a location yet."}
              </span>
            </div>
          )}
        </div>
      ) : null}
    </div>
  );
}

export default MapView;

/* --------------------------------- helpers --------------------------------- */

/** A tiny child that bumps `viewTick` on zoom changes so clustering re-runs. */
function ZoomWatcher({ onZoom }: { onZoom: () => void }): JSX.Element | null {
  useMapEvents({ zoomend: () => onZoom() });
  return null;
}
