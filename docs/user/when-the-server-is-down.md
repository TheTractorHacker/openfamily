# When the server is down

Orbitly keeps working when your server cannot be reached (a restart, an update, a home
internet outage, or your phone with no signal). The phone remembers what it last knew and
keeps what you do until the server answers again.

A small bar at the top of the map tells you what is going on:

- **Server unreachable. Showing last known. Will sync when it is back.** The app tries again
  by itself, a little less often the longer it takes (so it does not drain your battery).
  Tap **Try again** to check right now.
- **Syncing…** The server is back and things that were waiting are being sent.
- **Up to date** Everything has been sent. The bar then goes away.

## What you still see

- Everyone's **last known position**, with how long ago it was ("last seen 3 hours ago"). In
  Private circles too.
- Your circles, saved places, the latest chat messages, your check-in notifications and the trips
  you have already opened.

## What you can still do

- **Write chat messages.** They show "waiting to send", are kept on the phone (even if you close the
  app or restart the phone) and are sent in order, once, when the server is back.
- **Check in** or send a **Help alert**: it says "Not sent yet" and goes out by itself later.
- **SOS.** If the server cannot be reached, the screen says **SOS not sent yet**. It is kept and
  retried at once when there is a connection. Meanwhile you can tap **Text my emergency contacts**
  (opens your own messages app with your contacts and your last position, you press send, it uses
  your normal phone plan and does not need Orbitly) or **call emergency services**. If you are
  already safe, tap **I'm safe, cancel this SOS**.
- Your phone keeps recording **your own position**. When the server is back it is sent in order, so
  your history has no gap (up to about 12 hours of positions in a normal circle).

## What you cannot see or do until it is back

- **New movement of other people.** Their phones can only reach you through the server.
- Photo messages, creating or editing a place in a normal circle, joining a circle with a code,
  signing in with a password, adding a device.

You stay signed in. A network problem never signs you out; only the server saying your login is
no longer valid does.

## How many updates are waiting

**Settings, Help, Diagnostics** shows **Updates waiting** (positions, messages, check-ins) and a
**Send now** button.

More for administrators: [design notes](../design/OFFLINE_RESILIENCE.md).
