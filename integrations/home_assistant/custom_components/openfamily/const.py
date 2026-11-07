"""Constants for the Orbitly integration."""

from __future__ import annotations

DOMAIN = "openfamily"

CONF_URL = "url"
CONF_TOKEN = "token"
CONF_WEBHOOK_ID = "webhook_id"
CONF_WEBHOOK_SECRET = "webhook_secret"
CONF_SCAN_INTERVAL = "scan_interval"

DEFAULT_SCAN_INTERVAL = 60
MIN_SCAN_INTERVAL = 30
MAX_SCAN_INTERVAL = 900

# States reported by the server in place of a location.
STATE_HOME = "home"
STATE_NOT_HOME = "not_home"
STATE_UNKNOWN = "unknown"
STATE_UNAVAILABLE_PRIVATE = "unavailable_private_circle"
STATE_SHARING_OFF = "sharing_off"

# Events fired on the Home Assistant bus: ``openfamily_<kind>``.
EVENT_KINDS = (
    "arrival",
    "departure",
    "sos",
    "crash",
    "trip_start",
    "trip_end",
    "low_battery",
)
EVENT_PREFIX = "openfamily_"

# Webhook request headers (docs/integrations/home-assistant.md).
HEADER_SIGNATURE = "X-OpenFamily-Signature"
HEADER_TIMESTAMP = "X-OpenFamily-Timestamp"
HEADER_DELIVERY = "X-OpenFamily-Delivery"
HEADER_EVENT = "X-OpenFamily-Event"
WEBHOOK_MAX_SKEW = 300  # seconds; older or newer deliveries are rejected
WEBHOOK_MAX_BODY = 64 * 1024
