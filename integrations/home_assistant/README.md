# Orbitly for Home Assistant

Brings your self-hosted [Orbitly](https://github.com/TheTractorHacker/openfamily) circles into Home Assistant.

* a **device tracker** per family member (GPS only when the token allows it and the circle may be read by the server)
* **sensors**: battery, speed, place (`home` / place name / `not_home`), last seen, drives and driving distance in the last 24 h
* **binary sensors**: SOS active, possible crash
* **events** on the Home Assistant bus: `openfamily_arrival`, `openfamily_departure`, `openfamily_sos`, `openfamily_crash`, `openfamily_trip_start`, `openfamily_trip_end`, `openfamily_low_battery`
* updates by **polling** (every 60 s by default) and, optionally, by **signed webhook push**

It is read-only. It can never move anyone, change a setting or send a message.

## Privacy, in one paragraph

The token you create in Orbitly (Settings, Integrations) is limited to the circles and scopes you choose.
Without the *GPS position* scope Home Assistant only learns *home / away / place name* and battery.
For a **Private (end-to-end encrypted) circle** the server has no positions to give, so its members appear with the state
`unavailable_private_circle` and **no coordinates, no battery, no speed**. That is by design, not a bug.
Circles in the opt-in trusted-server mode are readable by the server and behave like normal circles.

## Install

### HACS (custom repository)

1. HACS, Integrations, menu, **Custom repositories**.
2. Repository `https://github.com/TheTractorHacker/openfamily`, category **Integration**.
3. Install **Orbitly** and restart Home Assistant.

HACS looks for `custom_components/<domain>` at the repository root of a repository it installs from. This repository keeps the
component under `integrations/home_assistant/`, so until it is published in its own repository (or HACS gains a path option) use the
manual install below, or copy the repository's `integrations/home_assistant` folder into a small repository of your own that has
`hacs.json` and `custom_components/openfamily` at its root. See "Status and limits" below.

### Manual

Copy `custom_components/openfamily` into your Home Assistant `config/custom_components/` and restart.

## Set up

1. In the Orbitly admin panel open **Settings, Integrations**, create a token (name it, tick the circles, tick what it may read) and copy it. It is shown once.
2. In Home Assistant: **Settings, Devices & services, Add integration, Orbitly**. Enter the server URL (for example `https://family.example.com`) and the token.
3. Optional, for instant events instead of waiting for the next poll:
   * In the integration's **Configure** dialog copy the webhook URL it shows, and paste your signing secret (shown once when you created the token, or generated with *New signing secret*).
   * In Orbitly, on the token, open **Webhook**, paste the URL and **Send test event**.
   * If Home Assistant is on your LAN and Orbitly is elsewhere, the Orbitly server has to be able to reach it. Private addresses need a server administrator to tick *Home Assistant is on my local network*. A public HTTPS address (for example Nabu Casa Cloud) needs nothing.

If a token is revoked, Home Assistant shows a **repair / re-authentication** prompt: create a new token and paste it.

## Entities

For each member, a device with:

| Entity | Notes |
|---|---|
| `device_tracker.<name>` | `home` / `not_home` / place name; `latitude` / `longitude` only when allowed. Attribute `location_unavailable_reason` says why not. |
| `sensor.<name>_battery` | percent |
| `sensor.<name>_speed` | m/s |
| `sensor.<name>_place` | `home`, a place name, `not_home`, `unavailable_private_circle`, `sharing_off`, `unknown` |
| `sensor.<name>_last_seen` | timestamp |
| `sensor.<name>_drives_24_h`, `sensor.<name>_driving_distance_24_h` | with the *Driving* scope |
| `binary_sensor.<name>_sos`, `binary_sensor.<name>_possible_crash` | with the *Events* scope |

## Events and automations

Each event carries `member_id`, `member_name`, `place`, `place_id`, `is_home`, `occurred_at`, `event_id`, and for SOS / crash a `location` object
(`{"available": true, "lat": ..., "lon": ...}` or `{"available": false, "reason": "unavailable_private_circle"}`).

Turn on the porch light when Alice arrives home after dark:

```yaml
automation:
  - alias: "Porch light when Alice arrives"
    trigger:
      - platform: event
        event_type: openfamily_arrival
        event_data:
          member_name: Alice
          is_home: true
    condition:
      - condition: sun
        after: sunset
    action:
      - service: light.turn_on
        target:
          entity_id: light.porch
```

Switch to "away" mode when everyone has left:

```yaml
automation:
  - alias: "Everyone left"
    trigger:
      - platform: state
        entity_id: [device_tracker.alice, device_tracker.bob]
        to: not_home
        for: "00:10:00"
    condition:
      - condition: not
        conditions:
          - condition: state
            entity_id: device_tracker.alice
            state: home
          - condition: state
            entity_id: device_tracker.bob
            state: home
    action:
      - service: alarm_control_panel.alarm_arm_away
        target:
          entity_id: alarm_control_panel.house
```

Flash the lights and notify on an SOS:

```yaml
automation:
  - alias: "Orbitly SOS"
    trigger:
      - platform: event
        event_type: openfamily_sos
    action:
      - service: notify.mobile_app_my_phone
        data:
          title: "SOS from {{ trigger.event.data.member_name }}"
          message: >-
            {% set loc = trigger.event.data.location %}
            {% if loc and loc.available %}
              Position: https://maps.google.com/?q={{ loc.lat }},{{ loc.lon }}
            {% else %}
              No position available ({{ loc.reason if loc else 'unknown' }}).
            {% endif %}
          data: { push: { interruption-level: critical } }
      - service: light.turn_on
        target: { entity_id: light.hallway }
        data: { flash: long, color_name: red }
```

Low battery reminder: `event_type: openfamily_low_battery` (data: `trigger.event.data.data.battery_pct`).

## Brand note

The integration ships no logo. "Home Assistant" is a trademark of the Open Home Foundation and is used here only to say what this
integration works with; this project is not affiliated with or endorsed by it. If you want an icon, add your own artwork under the integration's `brand/` folder (newer Home Assistant releases read it there; older ones use the brands repository) and do not use anyone else's trademarked artwork.

## Status and limits

* **Never run against a real Home Assistant by the authors at the time of writing.** The API client, the signature verification and the full
  config-flow / entity / webhook behaviour are covered by automated tests (see `tests/`), against a fake Orbitly server and a test Home Assistant core.
* No `charging` state: the Orbitly apps do not report it.
* Trip start events arrive together with trip end (the server segments trips after the fact); they are not live.
* Events from a Private circle exist only on the phones; Home Assistant never receives them.

## Development

```
cd integrations/home_assistant
pip install -r requirements_test.txt
python -m pytest
```

`tests/test_api.py` and `tests/test_webhook_auth.py` need only `aiohttp` and `pytest-asyncio`; `tests/test_ha_*.py` need
`pytest-homeassistant-custom-component` and are skipped when it is missing.
