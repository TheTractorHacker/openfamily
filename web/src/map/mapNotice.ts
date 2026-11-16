// Pure text for the basemap status banner (kept free of DOM imports so tests can load it).

export type BaseMapStatus = "loading" | "vector" | "fallback" | "unavailable";

/** Text of the banner shown on top of the map for a status; null = nothing to say. */
export function mapNoticeText(status: BaseMapStatus): string | null {
  if (status === "fallback") return "Vector map unavailable (tiles blocked or no WebGL). Showing the simple fallback map.";
  if (status === "unavailable")
    return "Map tiles could not be loaded (blocked or offline). Markers and places are still shown on the blank map.";
  return null;
}

