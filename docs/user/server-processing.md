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

## Circles that require the server (children and teens)

A circle admin can set **"No, server processing is required"** (circle > Encryption keys > Server processing >
Server processing for this circle), or tick **Everyone must use the server** when creating the circle. This is meant for
circles where the family needs the server to always have everyone's location, for example a child's or a teen's
phone, so nobody in that circle can keep their data from the server.

What it means in practice:

* People see it **before they join** ("Server processing: required").
* Each member still **confirms it once on their own phone** ("Review and consent"). Until they do, their phone
  sends nothing to that circle except help requests (SOS). The server refuses phone-only data from members of such
  a circle, so the rule is enforced, not just a suggestion.
* A member who does not want that can only **leave the circle**.
* The rule applies to child accounts too. Set up a child's phone together with the child and confirm it there.
* Switching to "required" is a signed entry in the key log, visible to every member.

## What an admin can and cannot do

| | Circle admin | Person who runs the server |
| --- | --- | --- |
| Turn server processing on or off for the whole circle | yes | no |
| Make the server the default for members, or "Phone only" | yes | no |
| Require server processing in a circle | yes | no |
| Turn automatic switching off for the whole server (members are then asked instead) | no | yes (admin web, Settings > Default for new members: untick "Apply automatically") |
| Switch **another person** on | **no** | **no** |
| Switch another person off | only by turning it off for the whole circle | no |
| Read a member's data who switched it off | no | no |

So an admin can **make the server the default**, **require it** (the person then confirms or leaves), or **turn
it off for everyone**. An admin can never put another person's data on the server without that person's own
phone signing it, and every such step is visible in the key log.

## Switch it off for the whole circle (admins)

Open the circle, **Encryption keys > Server processing > Server processing for this circle**, and switch off **Server
assistance**. From then on every member's phone keeps its data for the phones only. Copies the server already
holds stay until you delete them: use **Delete all copies of this circle** on the Server processing screen.

To stop using end-to-end encryption altogether, an admin can switch the circle to Normal in the circle settings.
The server then keeps readable locations for everyone in that circle.

## Related

* [Privacy modes explained](privacy-modes.md)
* [Server setup](../server-setup.md) (for the person who runs the server)
* [Privacy processing design](../design/PRIVACY_PROCESSING.md) (technical background)
