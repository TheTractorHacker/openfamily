# The attention icon

One small icon at the top of the app tells you when something needs you; tap it to see what and fix it.

Orbitly no longer puts notices across the top of the screen. When something needs you, a small
icon with a number appears in the top bar: on the map next to the round buttons, on the other tabs
at the right of the title. When nothing needs you, there is no icon.

| Colour | Means |
|---|---|
| Red | Something is broken: the server cannot be reached, you are signed out, location is off, or this phone's encryption key cannot be read. |
| Amber | You have a choice to make or an update to install. |
| Green | Just so you know (for example "Your circle uses the server"). |

The number is how many things are waiting. The icon takes the colour of the most serious one.

## What you see when you tap it

A sheet called **Needs your attention** with one card per item. Each card says what is going on in
one sentence, why it matters in another, and has one button that fixes it. Some cards also have
**Not now** (or **Keep on my phone**) and an **(i)** button with more detail.

Things that can show up:

- **An app update**, required or available, and which circles need a newer app. **How to update**
  explains where to get it. **Not now** hides an optional update until the app restarts.
- **Can't reach your server**, with the time it last synced. **Try again** checks right away. The
  map also shows a small **Offline** pill; it never blocks the map. See
  [When the server is down](when-the-server-is-down.md).
- **Please sign in again** when this phone's login ran out.
- **Nobody has sent an update** in a Private circle, with the most likely reason. **Fix it** opens
  the Delivery page of that circle.
- **Use the server for (circle)?** in a Private circle where your admin turned on server help.
  **Use the server** or **Keep on my phone** (see [Privacy modes](privacy-modes.md)). Your answer is
  remembered.
- **Use the server again for (circle)?** after you chose **Set this phone up again**. Your earlier
  choice was signed by the old key of this phone, so it no longer counts and the server stopped
  reading your locations. One tap on **Use the server again** signs it with the new key.
- **This phone is waiting for approval** or **its encryption key can't be read**. The button opens
  **Encryption keys** (see [Members and devices](members-and-devices.md)).
- **Location is off** or **only allowed while Orbitly is open**. **Fix it** opens Diagnostics, which
  has the right button for your phone (see [Battery and permissions](battery-and-permissions.md)).
- **Your server wants to join** (server administrators): approve only when the code matches.
