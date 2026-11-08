# Deployment profile: home or cloud

Tell the server whether it runs on hardware **your family owns** (a box at
home) or on **rented hardware** (a VPS or hosting company). This changes the
advice and the defaults the apps show; it never turns anything on for anyone.

| Profile | Meaning | Effect |
| --- | --- | --- |
| **Home** | You own the machine and the room it sits in. | The apps may suggest server help for people who want the full feature set. |
| **Cloud** | Someone else runs the machine or the network. | The apps suggest phone-to-phone privacy and warn before sharing readable copies with the server. |
| *Not chosen* | Treated as **Cloud**, the careful side. | |

Every circle admin and member still chooses on their own phone. Nobody, including
you, can consent for another person.

Set it in the admin web under **Settings, Deployment profile**, or seed a fresh
install with `DEPLOYMENT_PROFILE=home` in `.env`. The choice in Settings wins.

Related: [Privacy modes explained](../user/privacy-modes.md),
[Privacy processing design](../design/PRIVACY_PROCESSING.md).

## The server's own key (no extra container)

From the release that adds it, the server is its own circle device. It creates the key itself on first start
(`server_device` volume, `/data/server-device`), you approve it once on a phone, and the setup card on
**Settings** turns into a green **Server is processing**. Nothing to type and no extra container. See
[Server setup](../server-setup.md) for the three steps, the accepted trade-off (the key lives on the server's
own disk) and what a cloud server should do (`OPENFAMILY_DATA_KEY` encrypts the key file at rest).

**Defaults for new members.** Server processing is suggested when the profile is **Home** or the admin
chose the server as the default; **Cloud** and *not chosen* keep the suggestion on "Keep on my phone" until
you decide. Whatever is suggested, the person still taps for themselves.

## Members are on the server by default (auto-apply)

The member default (API `GET/PUT /api/admin/settings/member-defaults`; the admin web page for it may arrive in a later release):

| Setting | Home profile (default) | Cloud or not chosen (default) |
| --- | --- | --- |
| Default lane | Server | Phone |
| Auto-apply | On | Off (the app only asks) |

With auto-apply on, a member of a Private circle that has server help on, an approved server key and no earlier
choice gets "use the server" **signed by their own phone** the next time they open the app. It is the same
signature as tapping the button, it appears in the circle's key log, and the member sees a notice with a one-tap
**Keep on my phone** (which also deletes the copies the server holds of them). Nobody who ever chose is changed, and an
opt-out is permanent. Not auto-applied: circles that require server processing, child accounts, old apps (they apply
after updating) and phones that are not online. The background service cannot sign, so a member who never opens the
app is not switched.

This is **your policy**, not each person's consent in advance: say so to your family. After it applies, the server
(and you, as its operator) can read that member's location, trips and driving data, and backups include them.

**Who is not on yet.** `GET /api/admin/members-not-on-server` (and the circle's processing screen for circle admins)
lists members whose own lane is not Server: `no_choice` (covered at their next app open), `phone` (their choice;
nobody can change it for them) and `needs_update` (old app). `remind_text` is a message you can send.

## Circles that are already Private

Open the app as the circle admin: a card says **Let the server do the processing (recommended)**. One flow
approves the server, turns server help on and signs your own choice. Every other member then opens the app and
taps **Use the server**. For members on an old app, the sheet gives a **Message to send** and the circle shows
"needs update". If people cannot send at all, **Switch this circle to normal mode** makes the server keep
everyone's locations again: the encrypted copies and key copies the server held for that circle are deleted,
phone-only places and history stay on those phones, and every member is told.

> Availability: the deployment profile arrives with the release that adds it;
> see the [changelog](../CHANGELOG.md) for your version.
