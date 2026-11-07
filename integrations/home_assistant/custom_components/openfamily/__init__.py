"""Orbitly integration for Home Assistant."""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from aiohttp import web
from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed, ConfigEntryNotReady
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import OpenFamilyAuthError, OpenFamilyClient, OpenFamilyConnectionError, OpenFamilyError
from .const import (
    CONF_SCAN_INTERVAL,
    CONF_TOKEN,
    CONF_URL,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    DEFAULT_SCAN_INTERVAL,
    HEADER_DELIVERY,
    HEADER_SIGNATURE,
    HEADER_TIMESTAMP,
    WEBHOOK_MAX_BODY,
    WEBHOOK_MAX_SKEW,
)
from .coordinator import OpenFamilyCoordinator
from .webhook_auth import SeenCache, verify_signature

_LOGGER = logging.getLogger(__name__)

PLATFORMS = [Platform.DEVICE_TRACKER, Platform.SENSOR, Platform.BINARY_SENSOR]

type OpenFamilyConfigEntry = ConfigEntry[OpenFamilyCoordinator]


async def async_setup_entry(hass: HomeAssistant, entry: OpenFamilyConfigEntry) -> bool:
    session = async_get_clientsession(hass)
    try:
        client = OpenFamilyClient(session, entry.data[CONF_URL], entry.data[CONF_TOKEN])
    except ValueError as err:
        raise ConfigEntryNotReady("The configured Orbitly URL is invalid") from err
    try:
        info = await client.ping()
    except OpenFamilyAuthError as err:
        raise ConfigEntryAuthFailed("Orbitly token was rejected or revoked") from err
    except OpenFamilyConnectionError as err:
        raise ConfigEntryNotReady(f"Cannot reach the Orbitly server: {err}") from err
    except OpenFamilyError as err:
        raise ConfigEntryNotReady(str(err)) from err

    interval = int(entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL))
    coordinator = OpenFamilyCoordinator(hass, entry, client, list(info.get("scopes", [])), interval)
    coordinator.token_name = str(info.get("name", ""))
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator

    _register_webhook(hass, entry, coordinator)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(entry.add_update_listener(_async_reload))
    return True


async def async_unload_entry(hass: HomeAssistant, entry: OpenFamilyConfigEntry) -> bool:
    webhook_id = entry.data.get(CONF_WEBHOOK_ID)
    if webhook_id:
        webhook.async_unregister(hass, webhook_id)
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def _async_reload(hass: HomeAssistant, entry: OpenFamilyConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


def _register_webhook(hass: HomeAssistant, entry: OpenFamilyConfigEntry, coordinator: OpenFamilyCoordinator) -> None:
    """Accept signed pushes. Without a signing secret the webhook stays unregistered."""
    webhook_id = entry.data.get(CONF_WEBHOOK_ID)
    secret = entry.options.get(CONF_WEBHOOK_SECRET) or entry.data.get(CONF_WEBHOOK_SECRET)
    if not webhook_id or not secret:
        return
    handler = make_webhook_handler(secret, coordinator)
    webhook.async_register(hass, "openfamily", "Orbitly", webhook_id, handler, allowed_methods=["POST"])


def make_webhook_handler(secret: str, coordinator: OpenFamilyCoordinator) -> Any:
    seen = SeenCache()

    async def handle(hass: HomeAssistant, webhook_id: str, request: web.Request) -> web.Response:
        # The body is read with a hard cap before anything is parsed.
        if request.content_length is not None and request.content_length > WEBHOOK_MAX_BODY:
            return web.Response(status=413)
        chunks: list[bytes] = []
        total = 0
        async for chunk in request.content.iter_chunked(8192):
            total += len(chunk)
            if total > WEBHOOK_MAX_BODY:
                return web.Response(status=413)
            chunks.append(chunk)
        body = b"".join(chunks)
        if not verify_signature(
            secret,
            request.headers.get(HEADER_TIMESTAMP),
            request.headers.get(HEADER_SIGNATURE),
            body,
            now=time.time(),
            max_skew=WEBHOOK_MAX_SKEW,
        ):
            _LOGGER.warning("Rejected an Orbitly webhook delivery with a bad signature or timestamp")
            return web.Response(status=401)
        delivery = request.headers.get(HEADER_DELIVERY, "")
        if delivery and delivery != "0" and seen.seen(delivery):
            return web.Response(status=200)  # replay of a delivery we already processed
        try:
            payload = json.loads(body)
        except ValueError:
            return web.Response(status=400)
        if not isinstance(payload, dict):
            return web.Response(status=400)
        if payload.get("type") != "test":
            coordinator.handle_event(payload)
        return web.Response(status=200)

    return handle
