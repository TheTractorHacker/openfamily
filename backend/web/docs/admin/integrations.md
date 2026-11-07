# Integrations: Home Assistant and Dawarich

## Home Assistant

Show who is home, trigger automations when someone arrives, or light a lamp
when a child leaves school.

1. In the app (Settings, Integrations) create a **Home Assistant token**. It is
   read-only, scoped to the circles you choose, and shown once.
2. Install the OpenFamily custom component in Home Assistant and paste the
   server address and token.
3. Optionally enable signed webhooks for events.

Admins can see tokens and revoke them on the admin web. Full guide with
examples: [Home Assistant](../integrations/home-assistant.md).

![The OpenFamily card in Home Assistant](../integrations/ha-card.png)

## Dawarich

[Dawarich](https://dawarich.app) is a self-hosted location history viewer.
OpenFamily can push points to it, one way. Configure it under **Settings,
Dawarich**: address, API key, per-member mapping. Deleting points in OpenFamily
does not delete them in Dawarich. In Private circles the Dawarich bridge is an
approved device that members must allow. Design notes: [Dawarich](../design/DAWARICH.md).

## Privacy of integrations

Both only receive what the circle's [privacy mode](../user/privacy-modes.md)
allows. A person who keeps their data phone-only is not sent to either.
