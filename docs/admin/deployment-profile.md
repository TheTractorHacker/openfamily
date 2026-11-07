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

> Availability: the deployment profile arrives with the release that adds it;
> see the [changelog](../CHANGELOG.md) for your version.
