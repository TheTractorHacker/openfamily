# Orbitly on your watch (Wear OS and Apple Watch)

See your people, send "I'm OK" or SOS and reply to chat from a Wear OS or Apple watch, with your phone doing the work. The next sections are about **Wear OS**; the [Apple Watch](#apple-watch) section is at the end.

Orbitly has a watch app for **Wear OS 3 and newer**: Samsung Galaxy Watch 4 and
later, Google Pixel Watch, and other Wear OS 3+ watches. Older Samsung watches
that run **Tizen** (Galaxy Watch 3 and earlier, Galaxy Watch Active, Gear) are a
different system and are **not supported**.

The watch is a **companion to your phone**. It shows your people and lets you
send an "I'm OK", an SOS or a quick reply from your wrist. Your phone does the
real work, so Orbitly must be installed and signed in on the phone that the watch
is paired with.

## What you can do on the watch

- **People**: who is where ("At Home", "Driving 42 mph", "2 min ago"), battery,
  and for each person the place, how old the position is, and **Open on phone**.
- **Direction**: a simple arrow and distance to a person from where your watch is
  (if you allow location for Orbitly on the watch). There is no map on the watch.
- **I'm OK**: tells your circle you are fine, with where you are.
- **SOS**: press and hold, then you have 5 seconds to cancel. Your family is
  told. **Emergency services are not called.** If the watch says it could not
  send, call emergency services yourself.
- **Pause or resume sharing**, **quick replies** to your circle's chat (a fixed
  list such as "On my way"), unread count, and **alerts**.
- A **tile** with the people nearest to you and a **watch face complication**
  (nearest person, unread messages or "Sharing paused").
- If the phone is out of reach, the watch shows the last information it got,
  says how old it is and says "Phone not connected".

## Install

**From Google Play (when available):** open Orbitly in the Play Store on your
phone, choose the watch under "Install on more devices", or search for Orbitly in
the Play Store on the watch.

**From the release file (no Play Store):**

1. Download `orbitly-wear-<version>.apk` from the same release as the phone app.
   Check it against `SHA256SUMS-wear.txt`.
2. On the watch: Settings, About watch, Software, tap Software version 7 times to
   unlock Developer options. In Developer options turn on **ADB debugging** and
   **Debug over Wi-Fi** (watch and computer on the same Wi-Fi). Note the IP
   address and port shown.
3. On the computer: `adb connect <watch-ip>:<port>`, then
   `adb -s <watch-ip>:<port> install orbitly-wear-<version>.apk`.
   (Some watches ask you to pair with a code first: `adb pair <ip>:<pair-port>`.)
4. Open Orbitly on the phone first, then open the watch app.

The watch app and the phone app must be **the same release family and signed by
the same key**. Android only connects them when they match, which is also what
keeps other apps out. Mixing a Play-Store phone app with a release-file watch app
(or the other way round) will not connect.

On the phone, **Settings, Watch** shows if a watch is connected and has two
switches: "Send to my watch" and "Show Private circles".

## How it works

Your phone keeps your sign-in and your encryption keys. It sends the watch a
short summary (names, last places, battery, alerts) over the normal Bluetooth/Wi-Fi
link between a phone and its paired Wear OS watch. When you press something on
the watch, the watch asks the phone, and the phone does it.
The watch app has no internet permission and never talks to your server.

Because the phone does the work:

- the watch is only as up to date as the phone (when the phone is off or far
  away, the watch shows old data and cannot send anything);
- the **Orbitly app has to be running on the phone** for buttons on the watch to
  work. Orbitly keeps running on its own for location sharing, but if you
  swiped it away or Android stopped it, the watch tells you to open Orbitly on
  the phone.

## Privacy

- **Normal circles**: the watch shows the same things the phone shows.
- **Private circles**: the positions are readable only on phones. To show them on
  the watch, the phone sends them already readable to your watch. They travel
  only between your phone and your paired watch and are never sent to the server
  by this feature. They are, however, readable on the watch itself and are handled
  by Google Play services on both devices. If you do not want that, turn off
  **Settings, Watch, Show Private circles**: those people then do not appear on
  the watch at all.
- The watch keeps only the last summary. Signing out of Orbitly on the phone, or
  turning off "Send to my watch", removes it from the watch.
- Anyone who holds your unlocked watch can see that summary and press "I'm OK" or
  SOS, the same as someone holding your unlocked phone. Use a watch screen lock.

## Troubleshooting

- *"Open Orbitly on your phone"*: the phone has not sent anything yet, or you are
  signed out there. Open the app on the phone.
- *"Phone not connected"*: the watch is out of Bluetooth range or its link is
  off. The data shown is old; its age is next to the message.
- *Nothing shows in Settings, Watch*: the phone needs Google Play services and a
  paired Wear OS watch (through the Google "Wear OS" app).
- *Samsung phones*: allow Orbitly to run in the background
  ([Battery and permissions](battery-and-permissions.md)).

## Apple Watch

Orbitly has an Apple Watch app for **watchOS 9 or newer** that does the same as the Wear OS app, with your iPhone doing the work. **This app is new and has not yet been tried on a real watch.**

**Install.** Install Orbitly on your iPhone and sign in. Open the **Watch** app on the iPhone, find **Orbitly** and switch on **Show App on Apple Watch** (it also installs by itself when automatic app install is on). In Orbitly on the iPhone, **Settings, Watch** shows whether the watch is found and has the same two switches as on Android.

**What you can do.** People (name, where, how long ago, battery), a distance and direction arrow (north is at the top; it does not turn with your wrist), **SOS** (press and hold, 5 second countdown, Cancel), **I'm OK**, pause or resume sharing, quick replies with an unread count, and alerts. If the iPhone cannot be reached the watch says **"iPhone not reachable"** and shows the age of what it has. An SOS that could not be sent is shown as **not sent**: call emergency services yourself. Orbitly never calls them.

**Privacy.** The watch never has your sign-in or keys. The iPhone sends it names, places and battery directly (not through the server). For a Private circle the iPhone sends the readable version the same way; turn off **Settings, Watch, Show Private circles** to leave those people out. Signing out, or switching "Send to my watch" off, removes the data from the watch; if the watch is out of reach at that moment the removal is done as soon as it is back.

**Installed from the unsigned file (sideloading).** The unsigned `orbitly-<version>-unsigned.ipa` contains the watch app. The tool you re-sign with must **sign the watch app too**; some tools only sign the main app. If Orbitly does not show up in the Watch app on the iPhone, sign again with a tool that supports watch apps, or install without the watch part. A free Apple ID limits how many app identifiers you can create per week and a watch app needs one more; apps signed with a free Apple ID expire after 7 days.

Technical background: [Watch apps (design)](../design/WATCH_APPS.md) and [Apple Watch app](../design/WATCH_APPS_APPLE.md).
