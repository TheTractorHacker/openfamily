"""Verification of signed OpenFamily webhook deliveries (no Home Assistant imports).

Signature: ``X-OpenFamily-Signature: v1=hex(HMAC_SHA256(secret, "<timestamp>.<body>"))``.
The comparison is constant-time, the timestamp must be within ``max_skew``
seconds of now (limits replay of a captured request), and delivery ids are
remembered so an identical delivery is accepted only once.
"""

from __future__ import annotations

import hashlib
import hmac
import time
from collections import OrderedDict


def compute_signature(secret: str, timestamp: str, body: bytes) -> str:
    mac = hmac.new(secret.encode(), digestmod=hashlib.sha256)
    mac.update(timestamp.encode() + b"." + body)
    return "v1=" + mac.hexdigest()


def verify_signature(
    secret: str,
    timestamp: str | None,
    signature: str | None,
    body: bytes,
    *,
    now: float | None = None,
    max_skew: int = 300,
) -> bool:
    """True only for a fresh, correctly signed delivery."""
    if not secret or not timestamp or not signature:
        return False
    try:
        ts = int(timestamp)
    except ValueError:
        return False
    current = time.time() if now is None else now
    if abs(current - ts) > max_skew:
        return False
    expected = compute_signature(secret, timestamp, body)
    return hmac.compare_digest(expected.encode(), signature.encode())


class SeenCache:
    """Bounded memory of recent ids for de-duplication and replay rejection."""

    def __init__(self, size: int = 512) -> None:
        self._size = size
        self._items: OrderedDict[str, None] = OrderedDict()

    def seen(self, key: str) -> bool:
        """Return True if ``key`` was already recorded; record it otherwise."""
        if key in self._items:
            self._items.move_to_end(key)
            return True
        self._items[key] = None
        while len(self._items) > self._size:
            self._items.popitem(last=False)
        return False
