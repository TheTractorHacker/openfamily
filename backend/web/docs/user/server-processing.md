# Server processing: on by default, your choice to switch off

Orbitly circles are **Private** by default when your server can take part: locations are end-to-end encrypted
between the phones, and your own server joins the circle as one more device so it can draw maps, keep history and
build driving reports. Everyone is **on the server by default**. Anyone who prefers can switch it off for
themselves, circle by circle. This page explains what that means and where the switches are.

## What server processing is

In a Private circle every phone encrypts its location before it leaves the phone. Two kinds of keys exist:

* the **phone key**, which only the members' phones hold. Data sealed with it can be read by the phones and by
  nobody else, not even the server;
* the **server key**, which the phones hold **and** the server. Data sealed with it can also be read by the server.

"Server processing on" for you means: your phone seals your location, trips and driving data with the server key,
so the server can work with them. "Phone only" means: your phone uses the phone key, and your own phone does the
work (trips and reports are computed on the phone, which uses more battery; some features are limited).

Which key your phone uses is **your phone's own signed choice**. Nobody else can make it for you: not the circle
admin, not the person who runs the server, not the server itself. Every choice is written to the circle's key log,
which every member can see.

## What the server can read

When server processing is on for you, the server can read:

* where you are (your locations, speed and direction), your places, trips and driving reports, and your history;
* that copy is stored **readable** on the server. The person who runs the server, and anyone who gets a backup or a
  copy of its disk, can read it too. On a rented server (VPS) the hosting company could as well.

It still cannot read anything of members who switched it off. Whatever you choose, the server always sees some
facts: that you are a member, when your phone connects, roughly how much it uploads, and your network address.

Chat in a Private circle stays end-to-end encrypted between the phones either way.

## How it is switched on (nothing to do for most people)

1. **The server joins itself.** The first time the server starts it creates its own key and asks to join. The
   person who runs the server gets **"Your server wants to join"** on their phone, compares a short code with the
   admin page and taps **approve** once. See [Server setup](../server-setup.md).
2. **A new circle is Private, with your server.** Whoever creates a circle sees **Private, with your server
   (recommended)** already selected. One tap on **Create** turns the circle Private, switches server processing
   on, and makes the server the default for everyone who joins. If the server has not been approved yet, the app
   opens the "Your server wants to join" step right there (or tells you who has to approve it).
3. **Everyone else is put on the server by their own phone.** When a member joins and opens the app, their phone
   switches server processing on for them and shows a notice: *Your circle uses the server so maps, history and
   driving reports work. Tap to keep your data on your phone.* There is nothing to tap if that is fine.

## How to switch it off (opt out)

You can do this at any time, for each circle separately:

* **From the notice:** tap **Keep on my phone** on the notice you see after joining.
* **From Settings:** open **Settings > Server processing**, tap the circle, and switch off **Let the server
  process my data**. Confirm with **Keep on my phone**.
* **From the circle:** open the circle, then **Encryption keys > Server processing**. The row there says your
  real state ("On for you" or "Phone only").

When you switch it off, the app offers to **delete the copies the server already holds** of your data
(recommended). Backups and anything already exported (for example to Dawarich) cannot be deleted that way. Your
choice is final until you change it yourself: the app never switches you back on by itself.

Switching back on works the same way; the app shows the server's code so you can compare it.

## Require server processing (one switch for the owner)

The owner of a circle (a circle admin) has **one switch**: **Require server processing** (circle settings, shown for
Private circles that have your Orbitly server). It is **on by default for a new circle** that uses your server. When
it is on:

* **Everyone's phone sends its location to your Orbitly server for processing, and members cannot turn it off.**
  There is no question, no button and no "not choosing yet" state for them.
* **Every member's phone signs its own server choice by itself** the first time it runs, and again whenever the
  server's key or the key generation changes. The signature is made with that member's own phone key and shows in the
  circle's key log, exactly as if they had tapped. Nobody (not the admin, not the server) can sign it for them.
* Members see **"Your family admin requires server processing."** in their settings, with no opt-out control. A
  child's account works the same way.
* While a phone has not switched over yet (a new phone, a new server key, an update that has not reached it), its
  positions **keep arriving, encrypted for the family** (on the phone key). Nothing is ever held back and nothing is
  ever sent in the clear.
* The owner's screen (**Encryption keys > Server processing**) says in plain words **who is on the server** and
  **who is still catching up**.
* Turning the switch off is a signed policy change too. Members can then choose for themselves again.

**The honest consequence: the admin can force it.** Someone who runs the circle can decide that everyone's location
is processed by the server, and a member cannot refuse that and stay in the circle. A member who does not want it
can only **leave the circle**. Use the switch for what it is meant for: a family, a child's or a teen's phone, where
the people running the circle also run the server. What the server can read is described above. Server processing
never changes who can see a member's data in the app: that stays the circle.

An **existing** circle keeps the setting it has; nothing is switched to "required" for you. The owner turns the
switch on in the circle settings when they want it.

## What an admin can and cannot do

| | Circle admin | Person who runs the server |
| --- | --- | --- |
| Turn server processing on or off for the whole circle | yes | no |
| Make the server the default for members, or "Phone only" | yes | no |
| Require server processing in a circle (one switch) | yes | no |
| Turn automatic switching off for the whole server (members are then asked instead) | no | yes (admin web, Settings > Default for new members: untick "Apply automatically") |
| Switch **another person** on | **no** | **no** |
| Switch another person off | only by turning it off for the whole circle | no |
| Read a member's data who switched it off | no | no |

So an admin can **make the server the default**, **require it** (every member's phone then signs it by itself, and
the only way out is leaving the circle), or **turn it off for everyone**. An admin can never sign for another
person: each member's own phone signs their own choice, and every such step is visible in the key log.

## Switch it off for the whole circle (admins)

Open the circle, **Encryption keys > Server processing > Server processing for this circle**, and switch off **Server
assistance**. From then on every member's phone keeps its data for the phones only. Copies the server already
holds stay until you delete them: use **Delete all copies of this circle** on the Server processing screen.

To stop using end-to-end encryption altogether, an admin can switch the circle to Normal in the circle settings.
The server then keeps readable locations for everyone in that circle.

## If you reset your encryption keys, or replace your phone

**Reset my keys** (Encryption keys > Link another phone > *No other phone and no recovery phrase?*) revokes every
key of your account. Since v0.26.27 **the server keeps its key** (when your server is updated too):

1. Your new phone checks that the server key is the one your account already used (same key, same fingerprint, the
   key the server itself reports as its own) and **signs for it once** as part of the reset. This is a new entry in
   the key log, "server key attached". Only that exact key, only for your own account, only with your new phone's
   signature; the server's private key never leaves the server.
2. Your new phone then **signs the circle's settings again** (a new key generation for the server, wrapped to every
   member's phone and to the server) and its own choice. If the owner required server processing, that setting is
   kept as it was.
3. **Every other member's choice stays valid**, because it names the same server key. Nothing for them to do. Their
   phones pick up the new key generation by themselves the next time they are online.
4. Meanwhile their positions keep arriving: if the server refuses a server copy (because the settings are being
   renewed), the phone sends the family copy at once instead, then signs again. No position is dropped.
5. An old background process on your previous phone setup that still uses the replaced key is refused by the server
   and switches to your new key by itself.

As with any reset, members must approve your new key in each Private circle (or, if you created the circle, your
owner approval applies).

If your server is **not yet updated** (or the reset was done without the server key being kept), the old behaviour
applies: the server makes a new key, your phone approves it by itself, and every member's phone signs its choice
again for the new key without asking. It takes a little longer and the server cannot read older server-line history
until your phone has wrapped the new generation. **Update the server first, then the phones.**

The server's key changes **only** when someone with admin rights chooses **Replace the server key** on purpose, or in
a real compromise. A restart, a new container or a server update never creates a new key; it lives on its own
volume (see [Backups](../admin/backups.md) for saving and restoring it).

## Related

* [Privacy modes explained](privacy-modes.md)
* [Server setup](../server-setup.md) (for the person who runs the server)
* [Privacy processing design](../design/PRIVACY_PROCESSING.md) (technical background)
