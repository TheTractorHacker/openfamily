# Notifications: push, SMS and Apple push

Alerts (SOS, arrivals, check-ins, chat) reach phones in three ways. You only
need the first for Android.

## Android: built in (nothing to set up)

The app keeps a connection to your server and shows alerts as notifications.
Make sure the app is allowed to run in the background
([Battery and permissions](../user/battery-and-permissions.md)).
If phones sleep deeply, add ntfy (UnifiedPush):

```
COMPOSE_PROFILES=proxy,push
PUSH_ADDRESS=push.example.com
NTFY_BASE_URL=https://push.example.com
CADDYFILE=Caddyfile.with-push
```

Install the **ntfy** app on each phone. Details: [Push notifications](../push.md).

## iPhone: Apple push (APNs)

Needs an Apple developer account and a `.p8` key. Set the key id, team id and
bundle id in `.env` as described in [Push notifications](../push.md) and
[iOS release](../design/IOS_RELEASE.md).

## SMS for SOS (optional)

If you add an SMS provider (Twilio, Telnyx, Plivo or Amazon SNS), an SOS also
texts the sender's own emergency contacts, with a temporary link and no
coordinates. Set the provider in `.env` or in **Settings > Notifications** in the admin
web, and set `PUBLIC_BASE_URL=https://family.example.com`. Messages never claim
emergency services were called. Register your number where your country
requires it. Details: [SMS providers](../sms.md) and [Safety](../safety.md).

Push messages never contain a location, and by default not the person's name or
the message text either (`VERBOSE_PUSH=true` changes that).
