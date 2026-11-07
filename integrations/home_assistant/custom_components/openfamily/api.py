"""Minimal async client for the Orbitly Home Assistant API (read only).

Pure Python on top of aiohttp: no Home Assistant imports, so it is unit-tested
against a fake server. The token is only ever sent in the Authorization header
and is never included in exception messages or logs.
"""

from __future__ import annotations

import asyncio
import re
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import aiohttp

API_PREFIX = "/integrations/ha/v1"
TOKEN_RE = re.compile(r"^ofha_[A-Za-z0-9_-]{43}$")
REQUEST_TIMEOUT = 15


class OpenFamilyError(Exception):
    """Base error."""


class OpenFamilyConnectionError(OpenFamilyError):
    """The server could not be reached or answered garbage."""


class OpenFamilyAuthError(OpenFamilyError):
    """The token is invalid or revoked (HTTP 401)."""


class OpenFamilyScopeError(OpenFamilyError):
    """The token lacks the scope for this call (HTTP 403)."""


class OpenFamilyRateLimited(OpenFamilyError):
    """HTTP 429; ``retry_after`` is in seconds."""

    def __init__(self, retry_after: int) -> None:
        super().__init__(f"rate limited, retry after {retry_after}s")
        self.retry_after = retry_after


def normalize_url(raw: str) -> str:
    """Return ``scheme://host[:port]`` with no path, query or credentials.

    Raises ValueError for anything that is not a plain http(s) server address.
    """
    raw = (raw or "").strip()
    if "://" not in raw:
        raw = "https://" + raw
    parts = urlsplit(raw)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("invalid server URL")
    if parts.username or parts.password:
        raise ValueError("credentials in the URL are not allowed")
    return urlunsplit((parts.scheme, parts.netloc, "", "", ""))


def valid_token(token: str) -> bool:
    return bool(TOKEN_RE.match(token or ""))


class OpenFamilyClient:
    """Calls the ``/integrations/ha/v1`` endpoints."""

    def __init__(self, session: aiohttp.ClientSession, base_url: str, token: str) -> None:
        self._session = session
        self._base = normalize_url(base_url)
        self._token = token

    @property
    def base_url(self) -> str:
        return self._base

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        try:
            async with self._session.get(
                self._base + API_PREFIX + path,
                params=params,
                headers={"Authorization": f"Bearer {self._token}", "Accept": "application/json"},
                timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT),
                allow_redirects=False,
            ) as resp:
                if resp.status == 401:
                    raise OpenFamilyAuthError("token rejected")
                if resp.status == 403:
                    raise OpenFamilyScopeError("token lacks the required scope")
                if resp.status == 429:
                    try:
                        retry = int(resp.headers.get("Retry-After", "60"))
                    except ValueError:
                        retry = 60
                    raise OpenFamilyRateLimited(max(1, min(retry, 3600)))
                if resp.status != 200:
                    raise OpenFamilyConnectionError(f"unexpected HTTP status {resp.status}")
                try:
                    data = await resp.json(content_type=None)
                except (aiohttp.ContentTypeError, ValueError) as err:
                    raise OpenFamilyConnectionError("response was not JSON") from err
        except (aiohttp.ClientError, asyncio.TimeoutError) as err:
            # Deliberately do not chain the original message: it can contain the URL.
            raise OpenFamilyConnectionError(type(err).__name__) from None
        if not isinstance(data, dict):
            raise OpenFamilyConnectionError("unexpected response shape")
        return data

    async def ping(self) -> dict[str, Any]:
        """Return ``{"name", "scopes", "circles", ...}`` for the token."""
        return await self._get("/ping")

    async def members(self) -> dict[str, Any]:
        return await self._get("/members")

    async def places(self) -> dict[str, Any]:
        return await self._get("/places")

    async def events(self, after: int | None = None, limit: int = 50) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": limit}
        if after is not None:
            params["after"] = after
        return await self._get("/events", params)
