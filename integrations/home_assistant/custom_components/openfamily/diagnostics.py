"""Diagnostics with secrets, names and positions redacted."""

from __future__ import annotations

from typing import Any

from homeassistant.components.diagnostics import async_redact_data
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant

from .const import CONF_TOKEN, CONF_URL, CONF_WEBHOOK_ID, CONF_WEBHOOK_SECRET

TO_REDACT = {
    CONF_TOKEN,
    CONF_URL,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    "name",
    "member_name",
    "id",
    "member_id",
    "place",
    "place_id",
    "lat",
    "lon",
    "latitude",
    "longitude",
    "location",
    "state",
    "last_seen",
    "unique_id",
}


async def async_get_config_entry_diagnostics(hass: HomeAssistant, entry: ConfigEntry) -> dict[str, Any]:
    coordinator = entry.runtime_data
    data = coordinator.data or {}
    members = list(data.get("members", {}).values())
    return {
        "entry": async_redact_data({"data": dict(entry.data), "options": dict(entry.options)}, TO_REDACT),
        "scopes": coordinator.scopes,
        "last_update_success": coordinator.last_update_success,
        "member_count": len(members),
        "members": [async_redact_data(m, TO_REDACT) for m in members],
        "circles": [{"state": c.get("state")} for c in data.get("circles", [])],
        "last_event_type": (coordinator.last_event or {}).get("type"),
    }
