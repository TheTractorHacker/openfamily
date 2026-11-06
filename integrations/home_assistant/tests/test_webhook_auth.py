"""Signature verification, replay window and de-duplication (no Home Assistant needed)."""

from __future__ import annotations

import time

from conftest import load_pure

wa = load_pure("webhook_auth")
SECRET = "s3cret"
BODY = b'{"id":1,"type":"arrival"}'


def sign(ts: int, body: bytes = BODY, secret: str = SECRET) -> str:
    return wa.compute_signature(secret, str(ts), body)


def test_known_vector_matches_the_server_algorithm():
    # Same vector as backend/internal/handlers/ha_integrations_unit_test.go (TestHAWebhookSignatureVector).
    assert wa.compute_signature("secret", "1700000000", b'{"a":1}') == (
        "v1=49f24e537407743fa4a0242bb63b94b9a47ee99cbbe071ccd8a22550ae411686"
    )


def test_valid_signature_is_accepted():
    now = time.time()
    ts = int(now)
    assert wa.verify_signature(SECRET, str(ts), sign(ts), BODY, now=now)


def test_wrong_secret_body_or_format_is_rejected():
    now = time.time()
    ts = int(now)
    assert not wa.verify_signature(SECRET, str(ts), sign(ts, secret="other"), BODY, now=now)
    assert not wa.verify_signature(SECRET, str(ts), sign(ts), BODY + b" ", now=now)
    assert not wa.verify_signature(SECRET, str(ts), sign(ts).replace("v1=", "v2="), BODY, now=now)
    assert not wa.verify_signature(SECRET, str(ts), "", BODY, now=now)
    assert not wa.verify_signature(SECRET, None, sign(ts), BODY, now=now)
    assert not wa.verify_signature(SECRET, "not-a-number", sign(ts), BODY, now=now)
    assert not wa.verify_signature("", str(ts), sign(ts), BODY, now=now)


def test_old_and_future_timestamps_are_rejected_replay_window():
    now = time.time()
    old = int(now) - 301
    future = int(now) + 301
    assert not wa.verify_signature(SECRET, str(old), sign(old), BODY, now=now)
    assert not wa.verify_signature(SECRET, str(future), sign(future), BODY, now=now)
    edge = int(now) - 299
    assert wa.verify_signature(SECRET, str(edge), sign(edge), BODY, now=now)


def test_timestamp_is_bound_into_the_signature():
    now = time.time()
    ts = int(now)
    # A signature made for one timestamp cannot be reused with another.
    assert not wa.verify_signature(SECRET, str(ts + 1), sign(ts), BODY, now=now)


def test_seen_cache_dedupes_and_is_bounded():
    c = wa.SeenCache(size=3)
    assert c.seen("a") is False
    assert c.seen("a") is True
    for k in "bcd":
        c.seen(k)
    assert c.seen("a") is False  # evicted, so it is new again
