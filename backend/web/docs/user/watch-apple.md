# Apple Watch

Orbitly has an Apple Watch app (watchOS 9 or newer). It shows your circle on your wrist and
lets you do the urgent things quickly. Your iPhone does the real work: it keeps your sign-in
and your keys, and the watch asks it. The watch works while your iPhone is nearby (Bluetooth or
the same Wi-Fi) and shows the last information it received when it is not.

## Install

1. Install Orbitly on your iPhone and sign in.
2. Open the **Watch** app on the iPhone, scroll to **Orbitly** and switch on
   **Show App on Apple Watch**. With automatic app install on, it appears by itself.
3. In Orbitly on the iPhone, open **Settings, Watch** to see whether the watch is connected.

## What you can do

- **People**: everyone in your circle with their name, where they are (At Home, Driving 42 mph,
  or how long ago), and battery. Tap a person for the place, the address and how fresh it is.
- **Distance and direction**: an arrow that points towards the person, with the distance.
  North is at the top; the arrow does not turn when you turn your wrist.
- **SOS**: press and hold the red button, then a 5 second countdown starts. Press **Cancel** to
  stop. Your family is notified; emergency services are not contacted. If the iPhone cannot be
  reached the watch tells you the SOS was **not** sent, and you should call emergency services.
- **I'm OK**: sends a check-in to your circle.
- **Pause sharing / Resume sharing**.
- **Quick replies**: pick from a short fixed list (On my way, OK, Running late, Call me, Yes, No).
  The number shows unread messages.
- **Alerts**: recent alerts from your family.

## Privacy

The watch never has your password, sign-in or keys. The iPhone sends it only what it shows:
names, places, battery, distances. It travels directly from your iPhone to your watch and not
through the server. For Private circles the iPhone decrypts the information and sends the readable
version to your watch the same way. The watch keeps the last information until you sign out,
switch the watch off in **Settings, Watch**, or delete the watch app.

## If it does not work

- **"iPhone not reachable"**: bring the iPhone nearby, or open Orbitly on it once. The watch
  shows the age of what it has.
- **Not on the watch**: the Watch app on the iPhone must list Orbitly and the switch must be on.
- **Check-in says to open Orbitly**: open the app on the iPhone once so it knows your circle.

## Installed from the unsigned file (sideloading)

The unsigned `orbitly-<version>-unsigned.ipa` contains the watch app inside it. Whether it
reaches your watch depends on the tool you use to re-sign the app:

- The tool must **sign the watch app too** (the item inside the app). Some tools only sign the
  main app and drop or break the watch part. If the watch app does not show up in the Watch app
  on the iPhone, re-sign again with a tool that supports watch apps, or install without it.
- A free Apple ID limits how many app identifiers you can create per week, and a watch app
  needs one more than the iPhone app alone. If signing fails with a limit message, wait a week
  or remove the watch app from the file before signing.
- Apps signed with a free Apple ID expire after 7 days, the same as the iPhone app.

Technical background is in [Apple Watch app (design)](../design/WATCH_APPS_APPLE.md).
