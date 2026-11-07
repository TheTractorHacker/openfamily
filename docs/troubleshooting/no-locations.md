# "Nobody's location shows" in a Private circle

This page explains, in plain words, why a family can open OpenFamily, be in a Private
(end-to-end encrypted) circle, and see **no one**, and what the app now does about it.

## What happened to the Foley family

Their circle went private on 6 November 2026. Both people had app 0.21.1 on Android. Afterwards the
server held 807 encrypted updates, **all from one phone**. The other phone had never sent a single one.
Neither phone showed the other.

There were several separate problems. Any one of them gives an empty map, and the app used to say
only "No location yet" for all of them.

## The causes we found in the code

1. **A phone that was given the circle key never picked it up.** When a circle turns private, an
   admin's phone puts a locked copy of the circle key on the server for every member's phone. That
   copy is useless until the member's phone downloads and opens it. The only places that did this were
   the *Encryption keys* screens and a retry that only ran if the phone already had something to send.
   A phone without the key has nothing to send, so nothing ever triggered the download. It could
   neither send its own position nor read anyone else's. This is the most likely reason one phone
   never sent a single update.
   *Fix:* every time the app opens, resumes, or a position is taken without the key, the phone fetches
   its key first and then sends the positions that were waiting for it.

2. **The background part of the app could be out of date about the circle.** The background location
   service lives for days. It learned "this circle is private" once, and kept that answer. If it had
   learned it while the circle was still normal, it kept sending ordinary (readable) positions. The server
   refuses those for a private circle (error 409), so they were thrown away.
   *Fix:* the background service re-reads the circle settings on every position.

3. **Updates could be thrown away for a temporary reason.** A phone that was offline for a while, or whose
   login was being renewed, counted each failed attempt against its waiting updates and dropped them after
   20 attempts. A refusal from the server for a lasting reason (for example "this phone is not approved")
   dropped the updates silently.
   *Fix:* being offline or renewing a login never uses up an update. A lasting refusal is remembered and
   shown on the "Why can't I see everyone?" screen.

4. **Nothing was sent when the circle turned private, or when the app was opened.** The first view stayed
   empty until the next GPS position arrived (can be many minutes for a phone sitting still).
   *Fix:* when a circle turns private, and when the app is opened after a quiet spell, the phone
   immediately sends its last known position (with its original time, so it never pretends to be newer).

5. **Admin phones only shared keys when someone opened a screen.** A member who joined, or got a new
   phone, waited until an admin happened to open *Encryption keys*.
   *Fix:* an admin's phone now does the automatic, safe part of that whenever the app opens. Anything
   that needs a person's decision still asks.

6. **Not knowing why.** The app showed "No location yet" for a missing key, an old app, a switched-off
   phone, paused sharing and a bug alike.
   *Fix:* see "What you will see now".

### Things we checked and found fine

- **Server rules for ordinary circles.** Since 0.22 the server hides the stored position of a member who
  keeps their data on their phone. We tested that a member of a normal circle, a member of a private
  circle who lets the server help (server lane), and a member who is in both a private and a normal
  circle all still appear on the family list and on the live connection. Only a phone-only member of a
  private circle has no server position, which is the point of the feature.
- **Expiry and paging.** Live updates are kept 48 hours; the reading phone pages through everything
  after its saved place, oldest first, and never skips ahead past an update it could not open yet
  (those wait and are retried once the key arrives).
- **No readable fallback.** A private circle never sends a readable position as a fallback; a phone
  without the key keeps the position on the phone until it can seal it.

### One thing we could not prove from the code

Blake's updates stopped around 13:51 UTC. The code explains several ways that can happen (the phone
went offline and used up its 20 attempts, the login was being renewed, the phone was switched off, the
operating system stopped the background service). The server cannot tell these apart. Items 2 and 3 above
remove the code-side ones. If it happens again, the new screen shows whether the phone is queuing,
refused, or silent.

## What you will see now

- **People list, member card and map:** instead of "No location yet", the reason, for example
  - "Kinsley hasn't sent an encrypted update since 9:02 am (their phone may be off or the app closed)"
  - "Kinsley's phone has not received the circle key yet"
  - "Kinsley needs to update the app (v0.15.0 is too old)"
  - "Location sharing paused by Kinsley"
- **A banner** when everyone is silent: "You are in private mode and nobody has sent an update."
- **Circle settings, "Why can't I see everyone?"** shows each member's reason, what *this* phone has
  done (has the key, updates waiting, updates refused), and a **Fix this circle** button. It fetches the
  key, shares waiting keys (admin), seals waiting positions, sends your last position, uploads, and
  downloads what others sent, then lists what it did.
- **Admin web, Private circles, Delivery table** shows the same per-member reasons.

All of this uses only what the server already knows (who holds a key copy, when an encrypted update last
arrived to the minute, the app version, the sharing switch). `GET /circles/{id}/delivery` never returns or
touches a position.

## What to do, in order

1. Open OpenFamily on both phones and keep them open for a minute. Updates are sent immediately on open.
2. Tap **Circle settings, Why can't I see everyone?, Fix this circle** on the phone that sees nobody.
3. If someone is on an old app, update it. Private circles need 0.16 or newer, and per-member privacy
   settings need 0.22.
4. If a member's phone says "waiting for an admin to approve", an admin opens *Settings, Security,
   Encryption keys* for the circle.
5. Phones that are off, or where the system has stopped the app in the background, can only send once the
   app is opened again. On Android, allow OpenFamily to run in the background and exclude it from battery saving.
