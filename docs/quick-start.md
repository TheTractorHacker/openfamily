# Quick start (5 minutes)

From an empty server to your first shared location: install, sign in, approve the server, create a circle, invite people and install the app.

You need a computer that stays on (a small home server, a NAS with Docker, a Raspberry Pi 4 or newer, or a rented server) and
a phone. The long version of every step is linked, so you can start here and dig in only where you need to.

> **Tip** Pick the name of your circle later. Nothing here is permanent: you can rename a circle, add people and change
> the privacy mode whenever you like.

## 1. Install the server (about 3 minutes)

On the server, with Docker and Docker Compose v2 installed:

```bash
git clone https://github.com/TheTractorHacker/openfamily.git orbitly
cd orbitly
./scripts/setup.sh          # asks for your address, admin email and home/cloud, writes .env
docker compose up -d --build
curl http://localhost:8080/healthz   # {"status":"ok"}
```

Answer `:80` to the address question for a first test on your own network, or your domain name for the internet.
Answer **home** if the server is hardware you own, **cloud** for a rented server (you can change it later in the admin web).
The admin password is shown once: save it in a password manager.
More detail: [Install the server](admin/install.md). For a domain and HTTPS: [HTTPS and your own domain](admin/https-and-domain.md).

## 2. First sign-in

Open `http://localhost:8080/admin/` (or your domain plus `/admin/`) and sign in with the admin email and password.
Registration is closed, so only people with an invite code can join later. Details: [First run](admin/first-run.md).

## 3. Create an account and a circle in the app

1. Install the app on your phone ([Android](android-install-and-updates.md); on iPhone your admin gives you the install link).
2. Enter your server address, tap **Connect**, then create an account with the **same email** as the admin.
3. Choose **Create a new circle** (a circle can be a family, friends, a team) and give it a name.
   See [Create a circle](user/create-a-circle.md).

New circles are **Normal**: your server keeps locations, so the map, history and driving reports just work.
If you want locations readable only by phones, read [Concepts](concepts.md) first.

## 4. Approve your server (once)

Your server creates its own key the first time it starts. Your phone shows **"Your server wants to join"** with a short code
of four groups. Check that it is the same code as in the admin web under **Settings, Server setup**, then tap
**Yes, it matches - approve**. The setup card then turns green: **Server is processing**.
Only a server administrator can approve. More: [Server setup](server-setup.md).

> **Note** In a Normal circle the server already processes locations. Approving matters most when you use Private circles
> and want the server to help for the people who choose **Use the server**.

## 5. Invite your people

In the app open the circle, tap **Invite**, then **Create invite code**, and send the code or link by message.
They install the app, enter your server address, choose **Join a circle** and type the code.
See [Invite and join](user/invite-and-join.md).

## 6. Make it reliable on every phone

Each person should allow location **all the time**, allow notifications, and set battery use to unrestricted for Orbitly.
Without this, phones go quiet when the screen is off. See [Battery and permissions](user/battery-and-permissions.md).

## Check it worked

- [ ] `curl http://localhost:8080/healthz` answers `ok`
- [ ] You can sign in to the admin web
- [ ] Your circle shows you on the map
- [ ] A second phone joined with the invite code and appears
- [ ] The admin **Fleet** page shows both phones reporting

If something is missing, go to [Troubleshooting](troubleshooting/index.md).

## Next

- Set up backups before anything else: [Backups and restore](admin/backups.md)
- Understand the privacy choices: [Concepts](concepts.md) and [Privacy modes explained](user/privacy-modes.md)
- Words you may meet: [Glossary](glossary.md); quick answers: [FAQ](faq.md)
