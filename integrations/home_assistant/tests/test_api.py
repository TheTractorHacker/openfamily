"""API client tests against the fake server (no Home Assistant needed)."""

from __future__ import annotations

import aiohttp
import pytest
import pytest_asyncio

from conftest import load_pure
from fake_server import SECRET, TOKEN, FakeOpenFamily

api = load_pure("api")


@pytest_asyncio.fixture
async def server():
    s = FakeOpenFamily()
    await s.start()
    yield s
    await s.stop()


@pytest_asyncio.fixture
async def session():
    async with aiohttp.ClientSession() as s:
        yield s


async def test_ping_and_members(server, session):
    client = api.OpenFamilyClient(session, server.url, TOKEN)
    info = await client.ping()
    assert info["name"] == "Home Assistant"
    assert "location" in info["scopes"]
    data = await client.members()
    assert [m["name"] for m in data["members"]] == ["Alice", "Bob"]


async def test_private_circle_member_has_no_location_key(server, session):
    client = api.OpenFamilyClient(session, server.url, TOKEN)
    bob = (await client.members())["members"][1]
    assert bob["state"] == "unavailable_private_circle"
    assert "location" not in bob and bob["battery_pct"] is None


async def test_bad_token_is_auth_error_without_leaking_token(server, session):
    client = api.OpenFamilyClient(session, server.url, "ofha_" + "B" * 43)
    with pytest.raises(api.OpenFamilyAuthError) as exc:
        await client.members()
    assert "B" * 43 not in str(exc.value)


async def test_scope_and_rate_limit_errors(server, session):
    client = api.OpenFamilyClient(session, server.url, TOKEN)
    server.status_override = 403
    with pytest.raises(api.OpenFamilyScopeError):
        await client.places()
    server.status_override = 429
    with pytest.raises(api.OpenFamilyRateLimited) as exc:
        await client.members()
    assert exc.value.retry_after == 30


async def test_connection_error_does_not_leak_token_or_url(session):
    client = api.OpenFamilyClient(session, "http://127.0.0.1:1", TOKEN)
    with pytest.raises(api.OpenFamilyConnectionError) as exc:
        await client.ping()
    assert TOKEN not in str(exc.value) and "127.0.0.1" not in str(exc.value)


async def test_events_cursor(server, session):
    server.head = 5
    server.events = [{"id": 6, "type": "arrival"}, {"id": 7, "type": "departure"}]
    client = api.OpenFamilyClient(session, server.url, TOKEN)
    first = await client.events()
    assert first == {"events": [], "next_after": 5}
    nxt = await client.events(5)
    assert [e["id"] for e in nxt["events"]] == [6, 7] and nxt["next_after"] == 7


async def test_redirects_are_not_followed(session):
    from aiohttp import web

    async def redirect(_):
        raise web.HTTPFound("http://127.0.0.1:1/steal")

    app = web.Application()
    app.router.add_get("/integrations/ha/v1/members", redirect)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = runner.addresses[0][1]
    try:
        client = api.OpenFamilyClient(session, f"http://127.0.0.1:{port}", TOKEN)
        with pytest.raises(api.OpenFamilyConnectionError):
            await client.members()
    finally:
        await runner.cleanup()


def test_normalize_url_and_token_format():
    assert api.normalize_url("family.example.com/") == "https://family.example.com"
    assert api.normalize_url("http://192.168.1.5:8080/some/path?x=1") == "http://192.168.1.5:8080"
    for bad in ("ftp://x", "http://user:pw@host", "", "https://"):
        with pytest.raises(ValueError):
            api.normalize_url(bad)
    assert api.valid_token(TOKEN)
    assert not api.valid_token("ofha_short") and not api.valid_token("x" + TOKEN)
    assert SECRET  # keep the import used
