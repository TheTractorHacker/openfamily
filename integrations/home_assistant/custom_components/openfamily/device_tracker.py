"""Device trackers: one per member. GPS only when the server provides it."""

from __future__ import annotations

from typing import Any

from homeassistant.components.device_tracker import SourceType, TrackerEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import STATE_HOME, STATE_NOT_HOME, STATE_SHARING_OFF, STATE_UNAVAILABLE_PRIVATE, STATE_UNKNOWN
from .entity import OpenFamilyEntity, add_new_members


async def async_setup_entry(hass: HomeAssistant, entry, async_add_entities: AddEntitiesCallback) -> None:
    coordinator = entry.runtime_data
    known: set[str] = set()

    def _sync() -> None:
        add_new_members(coordinator, async_add_entities, known, lambda mid: [OpenFamilyTracker(coordinator, mid)])

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


class OpenFamilyTracker(OpenFamilyEntity, TrackerEntity):
    _attr_name = None  # the device (member) name is the entity name
    _attr_icon = "mdi:account"

    def __init__(self, coordinator, member_id: str) -> None:
        super().__init__(coordinator, member_id, "tracker")

    @property
    def source_type(self) -> SourceType:
        return SourceType.GPS

    @property
    def _location(self) -> dict[str, Any] | None:
        loc = (self.member or {}).get("location")
        return loc if isinstance(loc, dict) and loc.get("lat") is not None and loc.get("lon") is not None else None

    @property
    def latitude(self) -> float | None:
        loc = self._location
        return float(loc["lat"]) if loc else None

    @property
    def longitude(self) -> float | None:
        loc = self._location
        return float(loc["lon"]) if loc else None

    @property
    def location_accuracy(self) -> float:
        loc = self._location
        acc = loc.get("accuracy_m") if loc else None
        return float(acc) if acc is not None else 0.0

    @property
    def location_name(self) -> str | None:
        """Named state used when there are no coordinates (or none are allowed)."""
        m = self.member or {}
        state = m.get("state")
        if self._location and state not in (STATE_HOME,):
            # With coordinates HA derives zones itself; only forward "home" when the
            # server says so, so a Home place defined only in Orbitly still works.
            return None
        if state in (None, STATE_UNKNOWN, STATE_UNAVAILABLE_PRIVATE, STATE_SHARING_OFF):
            return None
        return state if state != STATE_NOT_HOME else STATE_NOT_HOME

    @property
    def battery_level(self) -> int | None:
        pct = (self.member or {}).get("battery_pct")
        return int(round(pct)) if pct is not None else None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        m = self.member or {}
        attrs: dict[str, Any] = {"openfamily_state": m.get("state"), "last_seen": m.get("last_seen")}
        if not m.get("location_available", False):
            attrs["location_unavailable_reason"] = m.get("unavailable_reason") or m.get("state")
        elif not self._location:
            attrs["location_unavailable_reason"] = "token_has_no_location_scope"
        if m.get("place"):
            attrs["place"] = m["place"].get("name")
        return attrs
