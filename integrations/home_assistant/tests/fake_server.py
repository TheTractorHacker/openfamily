"""A fake OpenFamily server for the Home Assistant integration tests."""

from __future__ import annotations

from typing import Any

from aiohttp import web

TOKEN = "ofha_" + "A" * 43
SECRET = "0123456789abcdef" * 4

HOME_MEMBER = {
    "id": "11111111-1111-4111-8111-111111111111",
    "name": "Alice",
    "state": "home",
    "location_available": True,
    "place": {"id": "p1", "name": "Home", "is_home": True},
    "battery_pct": 81.0,
    "speed_mps": 0.0,
    "last_seen": "2026-11-06T12:00:00Z",
    "location": {"lat": 52.52, "lon": 13.405, "accuracy_m": 8.0},
    "driving": {"drives_24h": 2, "distance_m_24h": 12500.0, "max_speed_mps_24h": 31.0, "last_drive_ended_at": None, "motion_state": "still"},
    "sos_active": False,
    "crash_active": False,
}
PRIVATE_MEMBER = {
    "id": "22222222-2222-4222-8222-222222222222",
    "name": "Bob",
    "state": "unavailable_private_circle",
    "location_available": False,
    "unavailable_reason": "unavailable_private_circle",
    "place": None,
    "battery_pct": None,
    "speed_mps": None,
    "last_seen": None,
    "sos_active": False,
    "crash_active": False,
}


class FakeOpenFamily:
    """Serves /integrations/ha/v1/* with a bearer-token check."""

    def __init__(self) -> None:
        self.token = TOKEN
        self.scopes = ["presence", "location", "places", "events", "driving"]
        self.members: list[dict[str, Any]] = [dict(HOME_MEMBER), dict(PRIVATE_MEMBER)]
        self.events: list[dict[str, Any]] = []
        self.head = 0
        self.status_override: int | None = None
        self.requests: list[str] = []
        self.runner: web.AppRunner | None = None
        self.url = ""

    def _auth(self, request: web.Request) -> web.Response | None:
        self.requests.append(request.path)
        if self.status_override:
            return web.json_response({"error": "x"}, status=self.status_override, headers={"Retry-After": "30"})
        if request.headers.get("Authorization") != f"Bearer {self.token}":
            return web.json_response({"error": "invalid_token"}, status=401)
        return None

    async def ping(self, request: web.Request) -> web.Response:
        if (r := self._auth(request)) is not None:
            return r
        return web.json_response({"api": 1, "name": "Home Assistant", "scopes": self.scopes, "circles": [{"id": "c1", "name": "Family", "state": "ok"}]})

    async def members_view(self, request: web.Request) -> web.Response:
        if (r := self._auth(request)) is not None:
            return r
        return web.json_response({"circles": [{"id": "c1", "name": "Family", "state": "ok"}], "members": self.members})

    async def places(self, request: web.Request) -> web.Response:
        if (r := self._auth(request)) is not None:
            return r
        return web.json_response({"circles": [], "places": []})

    async def events_view(self, request: web.Request) -> web.Response:
        if (r := self._auth(request)) is not None:
            return r
        after = request.query.get("after")
        if after is None:
            return web.json_response({"events": [], "next_after": self.head})
        evs = [e for e in self.events if e["id"] > int(after)]
        return web.json_response({"events": evs, "next_after": evs[-1]["id"] if evs else int(after)})

    async def start(self) -> None:
        app = web.Application()
        app.router.add_get("/integrations/ha/v1/ping", self.ping)
        app.router.add_get("/integrations/ha/v1/members", self.members_view)
        app.router.add_get("/integrations/ha/v1/places", self.places)
        app.router.add_get("/integrations/ha/v1/events", self.events_view)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        port = self.runner.addresses[0][1]
        self.url = f"http://127.0.0.1:{port}"

    async def stop(self) -> None:
        if self.runner:
            await self.runner.cleanup()
