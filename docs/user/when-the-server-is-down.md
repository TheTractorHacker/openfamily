# When the server is down

What Orbitly shows and keeps for you when your server cannot be reached, and what is sent once it is back.

Orbitly keeps working when your server cannot be reached (a restart, an update, a home internet outage, or a phone with no signal). The phone remembers what it last knew and keeps what you do until the server answers again.

A small pill at the top of the map tells you what is going on. It never blocks the map:

- **Offline · last synced 9:02.** The app tries again by itself, a little less often the longer it
  takes (so it does not drain your battery). The [attention icon](attention-icon.md) turns red and
  its card **Can't reach your server** has **Try again** to check right now.
- **Syncing…** The server is back and things that were waiting are being sent.
- **Up to date** Everything has been sent. The pill then goes away.

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

**Settings, Advanced, Diagnostics** shows **Updates waiting** (positions, messages, check-ins) and a
**Send now** button.

More for administrators: [design notes](../design/OFFLINE_RESILIENCE.md).

## What the error messages mean

- **This phone is offline**: the phone has no Wi-Fi or mobile data. Connect and try again.
- **Can't reach your server**: the phone is online but your server did not answer. It may be restarting or down; try again in a minute, and open **Settings, Advanced, Diagnostics** if it keeps happening.
- **No answer in time**: the request went out but the answer took too long, usually a weak connection.
- **Server busy**: your server is restarting or overloaded. Try again in a minute.
- **Sign in again**: your sign-in on this phone ended. Signing in again keeps everything on the phone.
- **Encryption key problem**: this phone's key is missing, locked or unreadable. Open **Encryption keys**.
- **Problem on this phone**: something failed in the app itself. Try again; if it repeats, send a report from **Settings, Advanced, Diagnostics**.
