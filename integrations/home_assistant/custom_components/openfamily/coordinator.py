"""Data coordinator: polls the members endpoint and merges pushed events."""

from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .api import (
    OpenFamilyAuthError,
    OpenFamilyClient,
    OpenFamilyConnectionError,
    OpenFamilyRateLimited,
    OpenFamilyScopeError,
)
from .const import DOMAIN, EVENT_KINDS, EVENT_PREFIX
from .webhook_auth import SeenCache

_LOGGER = logging.getLogger(__name__)


class OpenFamilyCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Holds ``{"members": {id: member}, "circles": [...]}``."""

    config_entry: ConfigEntry

    def __init__(
        self,
        hass: HomeAssistant,
        entry: ConfigEntry,
        client: OpenFamilyClient,
        scopes: list[str],
        interval: int,
    ) -> None:
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            config_entry=entry,
            update_interval=timedelta(seconds=interval),
        )
        self.client = client
        self.scopes = scopes
        self.token_name = ""
        self._event_cursor: int | None = None
        self._seen = SeenCache()
        self.last_event: dict[str, Any] | None = None

    async def _async_update_data(self) -> dict[str, Any]:
        try:
            payload = await self.client.members()
            if "events" in self.scopes:
                await self._poll_events()
        except OpenFamilyAuthError as err:
            raise ConfigEntryAuthFailed("Orbitly token was rejected or revoked") from err
        except OpenFamilyScopeError as err:
            raise UpdateFailed("The Orbitly token lacks the presence scope") from err
        except OpenFamilyRateLimited as err:
            raise UpdateFailed(f"Orbitly rate limit, retry in {err.retry_after}s") from err
        except OpenFamilyConnectionError as err:
            raise UpdateFailed(f"Cannot reach the Orbitly server: {err}") from err
        members = {m["id"]: m for m in payload.get("members", []) if isinstance(m, dict) and "id" in m}
        return {"members": members, "circles": payload.get("circles", [])}

    async def _poll_events(self) -> None:
        """Pull-side event feed: a fallback when the webhook is not (or no longer) reachable."""
        try:
            data = await self.client.events(self._event_cursor)
        except OpenFamilyScopeError:
            return
        if self._event_cursor is not None:
            for event in data.get("events", []):
                self.handle_event(event)
        nxt = data.get("next_after")
        if isinstance(nxt, int):
            self._event_cursor = nxt

    def handle_event(self, event: dict[str, Any]) -> bool:
        """Fire an event on the bus once. Returns True when it was new."""
        kind = event.get("type")
        if kind not in EVENT_KINDS:
            return False
        key = str(event.get("id", ""))
        if not key or self._seen.seen(key):
            return False
        member = event.get("member") or {}
        place = event.get("place") or {}
        data = {
            "event_id": event.get("id"),
            "member_id": member.get("id"),
            "member_name": member.get("name"),
            "place": place.get("name"),
            "place_id": place.get("id"),
            "is_home": place.get("is_home"),
            "occurred_at": event.get("occurred_at"),
            "location": event.get("location"),
            "data": event.get("data"),
        }
        self.last_event = {"type": kind, **{k: v for k, v in data.items() if k != "location"}}
        self.hass.bus.async_fire(EVENT_PREFIX + kind, data)
        # Reflect SOS / crash immediately; the next poll confirms or clears it.
        if kind in ("sos", "crash") and self.data:
            mid = member.get("id")
            current = self.data.get("members", {}).get(mid)
            if current is not None:
                current = dict(current)
                current["sos_active" if kind == "sos" else "crash_active"] = True
                members = dict(self.data["members"])
                members[mid] = current
                self.async_set_updated_data({**self.data, "members": members})
        return True
