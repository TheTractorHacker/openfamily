// BaseMapLayer — vector basemap (MapLibre GL via @maplibre/maplibre-gl-leaflet)
// inside a react-leaflet map, so Leaflet markers, popups, circles and
// polylines keep working on top. MapLibre is dynamically imported so it only
// loads on map pages. If WebGL is unavailable or the style fails to load, a
// raster Leaflet TileLayer is shown instead (never a blank map).

import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { TileLayer, useMap } from "react-leaflet";
import type { Layer } from "leaflet";
import "./BaseMapLayer.css";
import { mapNoticeText, type BaseMapStatus } from "./mapNotice";

export const DEFAULT_STYLE_URL = "https://tiles.openfreemap.org/styles/liberty";
export const DEFAULT_RASTER_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";

const ATTRIBUTION =
  '<a href="https://openfreemap.org" target="_blank" rel="noopener noreferrer">OpenFreeMap</a> ' +
  '&copy; <a href="https://www.openmaptiles.org/" target="_blank" rel="noopener noreferrer">OpenMapTiles</a> ' +
  'Data from <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap contributors</a>';

const FALLBACK_ATTRIBUTION = "&copy; OpenStreetMap contributors";

interface PublicConfig {
  styleUrl: string;
  rasterUrl: string;
}

let configPromise: Promise<PublicConfig> | null = null;

/** Reads map_style_url / tile_url from the public GET /config (cached). */
function loadConfig(): Promise<PublicConfig> {
  if (!configPromise) {
    configPromise = fetch("/config")
      .then((r) => (r.ok ? r.json() : {}))
      .catch(() => ({}))
      .then((c: Record<string, unknown>) => ({
        styleUrl:
          typeof c.map_style_url === "string" && c.map_style_url ? c.map_style_url : DEFAULT_STYLE_URL,
        rasterUrl: typeof c.tile_url === "string" && c.tile_url ? c.tile_url : DEFAULT_RASTER_URL,
      }));
  }
  return configPromise;
}

/**
 * Maps stay light in dark mode too: the dark basemap hides roads and labels
 * that matter here. A stock OpenFreeMap "dark" style falls back to "liberty";
 * any other configured style is used as is.
 */
export function lightStyle(styleUrl: string): string {
  const m = /^(https:\/\/tiles\.openfreemap\.org\/styles\/)dark$/.exec(styleUrl);
  return m ? m[1] + "liberty" : styleUrl;
}

function webglAvailable(): boolean {
  try {
    const c = document.createElement("canvas");
    return !!(c.getContext("webgl2") || c.getContext("webgl"));
  } catch {
    return false;
  }
}

/** Seconds a vector style may take to deliver its first tile before the raster fallback takes over. */
const VECTOR_TIMEOUT_MS = 8000;
/** Tile errors (with no tile ever arriving) after which a layer counts as blocked. */
const TILE_ERROR_LIMIT = 4;

/** Banner inside the map container so a blank basemap is never silent. */
function MapNotice({ status }: { status: BaseMapStatus }) {
  const map = useMap();
  const [dismissed, setDismissed] = useState<BaseMapStatus | null>(null);
  const text = mapNoticeText(status);
  if (!text || dismissed === status) return null;
  return createPortal(
    <div className="wb-map-notice" role="status">
      <span>{text}</span>
      <button type="button" className="wb-map-notice-x" aria-label="Dismiss" onClick={() => setDismissed(status)}>
        ×
      </button>
    </div>,
    map.getContainer(),
  );
}

export function BaseMapLayer({ rasterUrl }: { rasterUrl?: string }) {
  const map = useMap();
  const [cfg, setCfg] = useState<PublicConfig | null>(null);
  const [failed, setFailed] = useState(() => !webglAvailable());
  const [rasterDead, setRasterDead] = useState(false);

  useEffect(() => {
    let live = true;
    void loadConfig().then((c) => live && setCfg(c));
    return () => {
      live = false;
    };
  }, []);

  const style = cfg ? lightStyle(cfg.styleUrl) : null;

  useEffect(() => {
    if (!style || failed) return;
    let cancelled = false;
    let layer: Layer | null = null;
    let timer: number | undefined;
    const fail = () => {
      if (!cancelled) setFailed(true);
    };
    (async () => {
      try {
        const [, { maplibreGL }] = await Promise.all([
          import("maplibre-gl/dist/maplibre-gl.css"),
          import("@maplibre/maplibre-gl-leaflet"),
        ]);
        if (cancelled) return;
        const gl = maplibreGL({ style, attributionControl: false } as never);
        layer = gl;
        gl.addTo(map);
        gl.getContainer().style.zIndex = "0";
        const glMap = gl.getMaplibreMap();
        // Style or tile fetch problems => raster fallback. "load" alone is not enough: the style can load while every
        // tile is blocked or fails (a proxy, a blocked host, a GPU that cannot draw), which leaves a blank map. So the
        // vector layer only counts as working once a vector tile has actually arrived.
        timer = window.setTimeout(fail, VECTOR_TIMEOUT_MS);
        let tileErrors = 0;
        const onData = (e: { dataType?: string; tile?: unknown }) => {
          if (e.dataType === "source" && e.tile) {
            window.clearTimeout(timer);
            glMap.off("data", onData);
          }
        };
        glMap.on("data", onData);
        // Style document failed to load/parse => raster fallback.
        glMap.on("error", (ev) => {
          const e = ev as unknown as { tile?: unknown };
          if (!glMap.isStyleLoaded()) fail();
          else if (e.tile && ++tileErrors >= TILE_ERROR_LIMIT) fail();
        });
      } catch {
        fail();
      }
    })();
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      if (layer) map.removeLayer(layer);
    };
  }, [map, style, failed]);

  // Keep the attribution visible while the vector layer is active.
  useEffect(() => {
    if (failed || !cfg) return;
    map.attributionControl.addAttribution(ATTRIBUTION);
    return () => {
      map.attributionControl.removeAttribution(ATTRIBUTION);
    };
  }, [map, failed, cfg]);

  const handlers = useMemo(() => rasterHandlers(setRasterDead), []);
  const status: BaseMapStatus = failed ? (rasterDead ? "unavailable" : "fallback") : cfg ? "vector" : "loading";

  if (!cfg && !failed) return null;
  if (failed) {
    return (
      <>
        <TileLayer
          url={rasterUrl ?? cfg?.rasterUrl ?? DEFAULT_RASTER_URL}
          attribution={FALLBACK_ATTRIBUTION}
          eventHandlers={handlers}
        />
        <MapNotice status={status} />
      </>
    );
  }
  return null;
}

/** Marks the raster layer dead when its first few tiles all fail, and alive again as soon as one loads. */
function rasterHandlers(setDead: (dead: boolean) => void) {
  let errors = 0;
  let loaded = 0;
  return {
    tileerror: () => {
      errors += 1;
      if (loaded === 0 && errors >= TILE_ERROR_LIMIT) setDead(true);
    },
    tileload: () => {
      loaded += 1;
      setDead(false);
    },
  };
}
