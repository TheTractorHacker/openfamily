// BaseMapLayer — vector basemap (MapLibre GL via @maplibre/maplibre-gl-leaflet)
// inside a react-leaflet map, so Leaflet markers, popups, circles and
// polylines keep working on top. MapLibre is dynamically imported so it only
// loads on map pages. If WebGL is unavailable or the style fails to load, a
// raster Leaflet TileLayer is shown instead (never a blank map).

import { useEffect, useState } from "react";
import { TileLayer, useMap } from "react-leaflet";
import type { Layer } from "leaflet";

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

function currentTheme(): "light" | "dark" {
  const t = document.documentElement.getAttribute("data-theme");
  if (t === "dark" || t === "light") return t;
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

/** Use OpenFreeMap's dark style in dark mode when the stock OpenFreeMap style is configured. */
export function styleForTheme(styleUrl: string, theme: "light" | "dark"): string {
  const m = /^(https:\/\/tiles\.openfreemap\.org\/styles\/)(liberty|bright|positron|dark)$/.exec(styleUrl);
  if (!m) return styleUrl;
  if (theme === "dark") return m[1] + "dark";
  return styleUrl === m[1] + "dark" ? m[1] + "liberty" : styleUrl;
}

function webglAvailable(): boolean {
  try {
    const c = document.createElement("canvas");
    return !!(c.getContext("webgl2") || c.getContext("webgl"));
  } catch {
    return false;
  }
}

export function BaseMapLayer({ rasterUrl }: { rasterUrl?: string }) {
  const map = useMap();
  const [cfg, setCfg] = useState<PublicConfig | null>(null);
  const [theme, setTheme] = useState(currentTheme);
  const [failed, setFailed] = useState(() => !webglAvailable());

  useEffect(() => {
    let live = true;
    void loadConfig().then((c) => live && setCfg(c));
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    const obs = new MutationObserver(() => setTheme(currentTheme()));
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => obs.disconnect();
  }, []);

  const style = cfg ? styleForTheme(cfg.styleUrl, theme) : null;

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
        // Style or tile fetch problems before first render => raster fallback.
        timer = window.setTimeout(fail, 15000);
        glMap.once("load", () => window.clearTimeout(timer));
        // Style document failed to load/parse => raster fallback.
        glMap.on("error", () => {
          if (!glMap.isStyleLoaded()) fail();
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

  if (!cfg && !failed) return null;
  if (failed) {
    return <TileLayer url={rasterUrl ?? cfg?.rasterUrl ?? DEFAULT_RASTER_URL} attribution={FALLBACK_ATTRIBUTION} />;
  }
  return null;
}
