// Group/circle switcher — a control to filter the map to one group (family)
// or show all groups, with each group visually distinct via a colored dot.
// Mirrors the app's circle switcher intent, adapted for the multi-family admin
// panel (the app is single-circle; the admin sees every family).
//
// With a handful of groups it renders a one-tap horizontal chip row; with many
// groups it falls back to a dropdown.

import { useEffect, useRef, useState } from "react";
import type { Group } from "./types";

export interface GroupSwitcherProps {
  groups: Group[];
  /** Number of members per group id (for the count beside each option). */
  countsById: Map<string, number>;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  /** Accent color per group id. */
  colorsById: Map<string, string>;
}

/** Above this many groups, switch from a one-tap chip row to a dropdown. */
const CHIP_ROW_MAX = 6;

export function GroupSwitcher({
  groups,
  countsById,
  selectedId,
  onSelect,
  colorsById,
}: GroupSwitcherProps): JSX.Element {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // Close on outside click / Escape.
  useEffect(() => {
    if (!open) return;
    function onDown(e: MouseEvent): void {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    function onKey(e: KeyboardEvent): void {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const selectedName =
    selectedId == null
      ? "All groups"
      : groups.find((g) => g.id === selectedId)?.name ?? "All groups";
  const total = groups.reduce((sum, g) => sum + (countsById.get(g.id) ?? 0), 0);
  const chip = selectedId == null ? total : countsById.get(selectedId) ?? 0;

  // One-tap chip row for a handful of groups.
  if (groups.length <= CHIP_ROW_MAX) {
    return (
      <div className="wb-switcher wb-switcher-chips" ref={ref}>
        <button
          type="button"
          className="wb-switcher-chip-btn"
          data-active={selectedId == null ? "true" : "false"}
          onClick={() => onSelect(null)}
        >
          <GroupsIcon />
          <span>All</span>
          <span className="wb-switcher-count">{total}</span>
        </button>
        {groups.map((g) => (
          <button
            key={g.id}
            type="button"
            className="wb-switcher-chip-btn"
            data-active={selectedId === g.id ? "true" : "false"}
            onClick={() => onSelect(g.id)}
          >
            <span
              className="wb-switcher-dot"
              style={{ background: colorsById.get(g.id) ?? "var(--purple)" }}
            />
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {g.name}
            </span>
            <span className="wb-switcher-count">{countsById.get(g.id) ?? 0}</span>
          </button>
        ))}
      </div>
    );
  }

  return (
    <div className="wb-switcher" ref={ref}>
      <button
        type="button"
        className="wb-switcher-btn"
        aria-expanded={open}
        aria-haspopup="listbox"
        onClick={() => setOpen((o) => !o)}
      >
        {selectedId != null ? (
          <span className="wb-switcher-dot" style={{ background: colorsById.get(selectedId) ?? "var(--purple)" }} />
        ) : (
          <GroupsIcon />
        )}
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{selectedName}</span>
        <span className="wb-switcher-chip">{chip}</span>
        <span className="wb-switcher-caret">{open ? "▲" : "▼"}</span>
      </button>
      {open ? (
        <div className="wb-switcher-menu" role="listbox">
          <button
            type="button"
            role="option"
            aria-selected={selectedId == null}
            data-active={selectedId == null ? "true" : "false"}
            className="wb-switcher-item"
            onClick={() => {
              onSelect(null);
              setOpen(false);
            }}
          >
            <GroupsIcon />
            <span>All groups</span>
            <span className="wb-switcher-count">{total}</span>
          </button>
          {groups.map((g) => (
            <button
              key={g.id}
              type="button"
              role="option"
              aria-selected={selectedId === g.id}
              data-active={selectedId === g.id ? "true" : "false"}
              className="wb-switcher-item"
              onClick={() => {
                onSelect(g.id);
                setOpen(false);
              }}
            >
              <span className="wb-switcher-dot" style={{ background: colorsById.get(g.id) ?? "var(--purple)" }} />
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{g.name}</span>
              <span className="wb-switcher-count">{countsById.get(g.id) ?? 0}</span>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function GroupsIcon(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" width="15" height="15" fill="var(--purple)" aria-hidden="true">
      <path d="M8 4a3 3 0 1 0 0 6 3 3 0 0 0 0-6zm8 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM4 14a4 4 0 0 1 8 0v1H4v-1zm12 0a4 4 0 0 1 4 4v1h-6v-1a4 4 0 0 1 2-4z" />
    </svg>
  );
}
