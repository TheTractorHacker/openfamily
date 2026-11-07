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

## Circles that are already Private

Open the app as the circle admin: a card says **Let the server do the processing (recommended)**. One flow
approves the server, turns server help on and signs your own choice. Every other member then opens the app and
taps **Use the server**. For members on an old app, the sheet gives a **Message to send** and the circle shows
"needs update". If people cannot send at all, **Switch this circle to normal mode** makes the server keep
everyone's locations again: the encrypted copies and key copies the server held for that circle are deleted,
phone-only places and history stay on those phones, and every member is told.

> Availability: the deployment profile arrives with the release that adds it;
> see the [changelog](../CHANGELOG.md) for your version.
