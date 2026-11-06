"""Integration tests with Home Assistant (pytest-homeassistant-custom-component) and a fake server."""

from __future__ import annotations

import json
import time

import pytest
import pytest_asyncio
from homeassistant import config_entries
from homeassistant.components.diagnostics import REDACTED
from homeassistant.config_entries import ConfigEntryState
from homeassistant.core import HomeAssistant
from homeassistant.setup import async_setup_component
from pytest_homeassistant_custom_component.common import MockConfigEntry
from pytest_homeassistant_custom_component.components.diagnostics import get_diagnostics_for_config_entry

from custom_components.openfamily.const import (
    CONF_TOKEN,
    CONF_URL,
    CONF_WEBHOOK_ID,
    CONF_WEBHOOK_SECRET,
    DOMAIN,
)
from custom_components.openfamily.webhook_auth import compute_signature

from fake_server import SECRET, TOKEN, FakeOpenFamily

WEBHOOK_ID = "test_webhook_id_0123456789"


@pytest_asyncio.fixture
async def server():
    s = FakeOpenFamily()
    await s.start()
    yield s
    await s.stop()


async def _setup(hass: HomeAssistant, server: FakeOpenFamily, secret: str | None = SECRET) -> MockConfigEntry:
    options = {CONF_WEBHOOK_SECRET: secret} if secret else {}
    entry = MockConfigEntry(
        domain=DOMAIN,
        title="OpenFamily",
        unique_id="abc",
        data={CONF_URL: server.url, CONF_TOKEN: TOKEN, CONF_WEBHOOK_ID: WEBHOOK_ID},
        options=options,
    )
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


def _signed(payload: dict, *, ts: int | None = None, secret: str = SECRET, delivery: str = "1"):
    body = json.dumps(payload).encode()
    stamp = str(int(time.time()) if ts is None else ts)
    headers = {
        "X-OpenFamily-Timestamp": stamp,
        "X-OpenFamily-Signature": compute_signature(secret, stamp, body),
        "X-OpenFamily-Delivery": delivery,
        "Content-Type": "application/json",
    }
    return body, headers


async def test_config_flow_creates_entry(hass: HomeAssistant, server) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    assert result["type"] == "form"
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {CONF_URL: server.url, CONF_TOKEN: TOKEN})
    assert result["type"] == "create_entry"
    assert result["data"][CONF_TOKEN] == TOKEN and result["data"][CONF_WEBHOOK_ID]
    # The same server and token cannot be added twice.
    again = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    again = await hass.config_entries.flow.async_configure(again["flow_id"], {CONF_URL: server.url, CONF_TOKEN: TOKEN})
    assert again["type"] == "abort" and again["reason"] == "already_configured"


@pytest.mark.parametrize(
    ("token", "url", "key", "error"),
    [
        ("ofha_" + "B" * 43, None, "base", "invalid_auth"),
        ("nope", None, CONF_TOKEN, "invalid_token_format"),
        (TOKEN, "http://127.0.0.1:1", "base", "cannot_connect"),
        (TOKEN, "ftp://x", CONF_URL, "invalid_url"),
    ],
)
async def test_config_flow_errors(hass: HomeAssistant, server, token, url, key, error) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {CONF_URL: url or server.url, CONF_TOKEN: token})
    assert result["type"] == "form" and result["errors"] == {key: error}


async def test_entities_and_privacy(hass: HomeAssistant, server) -> None:
    await _setup(hass, server)
    alice = hass.states.get("device_tracker.alice")
    assert alice is not None
    assert alice.attributes["latitude"] == 52.52 and alice.attributes["longitude"] == 13.405
    assert alice.attributes["battery_level"] == 81
    # A member of a Private circle: no coordinates at all, and the reason is explicit.
    bob = hass.states.get("device_tracker.bob")
    assert bob is not None
    assert "latitude" not in bob.attributes and "longitude" not in bob.attributes
    assert bob.attributes["location_unavailable_reason"] == "unavailable_private_circle"
    assert bob.state == "unknown"
    assert hass.states.get("sensor.alice_battery").state == "81"
    assert hass.states.get("sensor.bob_battery").state == "unknown"
    assert hass.states.get("sensor.alice_place").state == "home"
    assert hass.states.get("binary_sensor.alice_sos").state == "off"
    assert hass.states.get("sensor.alice_drives_24_h").state == "2"


async def test_signed_webhook_fires_event_once_and_rejects_forgeries(hass: HomeAssistant, hass_client_no_auth, server) -> None:
    assert await async_setup_component(hass, "webhook", {})
    await _setup(hass, server)
    client = await hass_client_no_auth()
    fired: list = []
    hass.bus.async_listen("openfamily_arrival", lambda e: fired.append(e))
    payload = {
        "id": 41, "type": "arrival", "occurred_at": "2026-11-06T12:00:00Z",
        "member": {"id": "11111111-1111-4111-8111-111111111111", "name": "Alice"},
        "place": {"id": "p1", "name": "Home", "is_home": True},
    }
    body, headers = _signed(payload)
    resp = await client.post(f"/api/webhook/{WEBHOOK_ID}", data=body, headers=headers)
    assert resp.status == 200
    await hass.async_block_till_done()
    assert len(fired) == 1 and fired[0].data["place"] == "Home" and fired[0].data["member_name"] == "Alice"
    # Replay: same delivery id and same event id never fires twice.
    resp = await client.post(f"/api/webhook/{WEBHOOK_ID}", data=body, headers=headers)
    assert resp.status == 200
    await hass.async_block_till_done()
    assert len(fired) == 1
    # Forged signature, wrong secret, stale timestamp, missing headers: all 401, nothing fires.
    body2, good = _signed({**payload, "id": 42}, delivery="2")
    for hdrs in (
        {**good, "X-OpenFamily-Signature": "v1=" + "0" * 64},
        _signed({**payload, "id": 43}, secret="wrong", delivery="3")[1],
        _signed({**payload, "id": 44}, ts=int(time.time()) - 3600, delivery="4")[1],
        {"Content-Type": "application/json"},
    ):
        resp = await client.post(f"/api/webhook/{WEBHOOK_ID}", data=body2, headers=hdrs)
        assert resp.status == 401
    await hass.async_block_till_done()
    assert len(fired) == 1


async def test_sos_webhook_turns_binary_sensor_on(hass: HomeAssistant, hass_client_no_auth, server) -> None:
    assert await async_setup_component(hass, "webhook", {})
    await _setup(hass, server)
    client = await hass_client_no_auth()
    payload = {
        "id": 50, "type": "sos", "occurred_at": "2026-11-06T12:00:00Z",
        "member": {"id": "11111111-1111-4111-8111-111111111111", "name": "Alice"},
        "location": {"available": False, "reason": "unavailable_private_circle"},
    }
    body, headers = _signed(payload, delivery="50")
    assert (await client.post(f"/api/webhook/{WEBHOOK_ID}", data=body, headers=headers)).status == 200
    await hass.async_block_till_done()
    assert hass.states.get("binary_sensor.alice_sos").state == "on"


async def test_webhook_not_registered_without_secret_events_arrive_by_polling(hass: HomeAssistant, hass_client_no_auth, server) -> None:
    assert await async_setup_component(hass, "webhook", {})
    entry = await _setup(hass, server, secret=None)
    client = await hass_client_no_auth()
    body, headers = _signed({"id": 1, "type": "arrival"})
    assert (await client.post(f"/api/webhook/{WEBHOOK_ID}", data=body, headers=headers)).status == 200  # HA answers 200 for unknown ids
    fired: list = []
    hass.bus.async_listen("openfamily_departure", lambda e: fired.append(e))
    # First poll only learned the cursor; a new event is then picked up by the next poll.
    server.events = [{"id": 9, "type": "departure", "occurred_at": "x", "member": {"id": "m", "name": "Alice"}, "place": {"id": "p", "name": "Home", "is_home": True}}]
    server.head = 9
    await entry.runtime_data.async_refresh()
    await entry.runtime_data.async_refresh()
    await hass.async_block_till_done()
    assert len(fired) == 1


async def test_revoked_token_starts_reauth(hass: HomeAssistant, server) -> None:
    entry = await _setup(hass, server)
    server.token = "ofha_" + "Z" * 43  # the server no longer accepts ours
    await entry.runtime_data.async_refresh()
    await hass.async_block_till_done()
    flows = hass.config_entries.flow.async_progress_by_handler(DOMAIN)
    assert any(f["context"]["source"] == config_entries.SOURCE_REAUTH for f in flows)


async def test_setup_retry_when_server_is_down(hass: HomeAssistant, server) -> None:
    await server.stop()
    entry = MockConfigEntry(domain=DOMAIN, data={CONF_URL: server.url, CONF_TOKEN: TOKEN, CONF_WEBHOOK_ID: WEBHOOK_ID})
    entry.add_to_hass(hass)
    await hass.config_entries.async_setup(entry.entry_id)
    assert entry.state is ConfigEntryState.SETUP_RETRY
    server.runner = None


async def test_diagnostics_redacts_secrets_names_and_positions(hass: HomeAssistant, hass_client, server) -> None:
    entry = await _setup(hass, server)
    diag = await get_diagnostics_for_config_entry(hass, hass_client, entry)
    dumped = json.dumps(diag)
    for secret in (TOKEN, SECRET, WEBHOOK_ID, server.url, "Alice", "Bob", "52.52", "13.405", "11111111-1111"):
        assert secret not in dumped, secret
    assert diag["entry"]["data"][CONF_TOKEN] == REDACTED
    assert diag["member_count"] == 2
