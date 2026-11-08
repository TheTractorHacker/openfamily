# Glossary

The words Orbitly uses, in alphabetical order, in plain language.

**Admin web** The website that comes with your server, at `/admin/`. Server admins use it to see circles, phones, backups and these documents.

**APK** The installable file for Android. Orbitly publishes `orbitly-<version>.apk` with every release. See [Android install](android-install-and-updates.md).

**Approve the server** The one-time tap on your phone that lets your server join your circles as a helper. See [Server setup](server-setup.md).

**Audit log** A list of who looked at what (for example a server admin viewing a member). Circles can read the log about themselves.

**Backup** A copy of the database saved elsewhere so you can restore after a failure. See [Backups](admin/backups.md).

**Circle** A group of people who share their location with each other: a family, friends, a team. Called "family" in some screens. See [Create a circle](user/create-a-circle.md).

**Circle admin** The person who manages a circle: invites, removes, changes the privacy mode. Not the same as a server admin.

**Check-in** A short message that tells your circle you arrived safely, or that you are fine. See [Safety and check-ins](user/safety-and-check-ins.md).

**Compose (Docker Compose)** The tool that starts the server and its database with one command: `docker compose up -d`.

**Fleet** The admin web page listing which phones are reporting, with app version, battery and permission state.

**Geofence / Place** A saved spot such as Home or School. Orbitly can tell the circle when someone arrives or leaves. See [Places](user/places.md).

**Invite code** A short code or link a circle admin sends so that someone can join. Codes expire. See [Invite and join](user/invite-and-join.md).

**Keep on my phone** Your choice in a Private circle: your data stays locked and only phones process it. See [Concepts](concepts.md).

**Lane** The technical word for the choice between "phones only" and "server helps". In the app it appears as **Keep on my phone** and **Use the server**.

**Normal circle** A circle where the server can read positions and does the processing: the default for new circles.

**Private circle** A circle where positions are locked on phones with a key the server does not have. See [Privacy modes explained](user/privacy-modes.md).

**Push notification** An alert delivered to your phone even when the app is closed. See [Notifications](admin/notifications.md).

**Release** A numbered version of Orbitly (for example 0.24). The server works with the last five minor versions of the app. See [App versions](admin/app-versions.md).

**Server admin** The person who installs and looks after the server. Often the same person as the circle admin.

**Server processing** The server turns positions into maps, trips, driving reports and alerts. Always on in Normal circles; each person's choice in Private circles.

**Session** A signed-in phone or browser. You can end old sessions under **Settings, Security, Active sessions**.

**SOS** The button that alerts your circle. It never calls emergency services. See [Safety](user/safety-and-check-ins.md).

**Two-step sign-in (MFA)** A second proof, such as a code from an authenticator app, when you sign in. Recommended for admins.
