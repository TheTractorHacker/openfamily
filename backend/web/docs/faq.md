# Frequently asked questions

Short answers to the questions families and friends ask most, with a link to the page that explains more.

## Basics

**What is Orbitly?** A private, self-hosted way for a circle of people (family, friends, a team) to share locations, get arrival alerts,
chat and send an SOS. It runs on a server you control. See [Getting started](user/getting-started.md).

**Is it only for families?** No. A circle can be a family, a group of friends, a carpool or a team. Some screens still say "family".

**Was Orbitly called something else?** Yes, OpenFamily. Your server, accounts and circles keep working after the rename. See [Credits and license](about/credits-and-license.md).

**Does it cost money?** The software is free and open source (AGPL-3.0). You pay for whatever runs the server, if anything.

**Is there an iPhone app? A watch app?** Orbitly has Android and iPhone apps. Wear OS and Apple Watch apps are coming; they are not available yet.

## Privacy

**Can the person who runs the server see where I am?** In a Normal circle the server can read positions. In a Private circle it cannot, unless you choose
**Use the server** for yourself. See [Concepts](concepts.md).

**Can a server admin watch members on the map?** Not by default. It is a separate switch (`ADMIN_LOCATION_ACCESS`), off by default, and every look is logged. See [Operator privacy controls](privacy-controls.md).

**Is chat private?** In a Private circle chat is end-to-end encrypted and the server never reads it. In a Normal circle chat is stored readable on the server. See [Family chat](user/chat.md).

**Does server processing mean my data is sent to a company?** No. "The server" is the one you or your family run, not a service run by Orbitly.

## Using it

**Why is nobody on the map?** Start with [Nobody shows on the map](troubleshooting/index.md#nobody-shows-on-the-map).

**What happens when the phone has no signal?** Updates wait on the phone and are sent when the connection returns. See [Concepts](concepts.md#offline-behaviour).

**Does it drain the battery?** Normal circles use the least; phone-side reports in Private circles use more. See [Battery and permissions](user/battery-and-permissions.md).

**Can I pause sharing?** Yes, per circle: turn off **Share my location**. See [Create a circle](user/create-a-circle.md#circle-details).

**Does SOS call the emergency services?** No. It alerts your circle. See [Safety and check-ins](user/safety-and-check-ins.md).

## Running the server

**What do I need?** A machine with Docker that stays on, about 1 GB of free RAM and a few GB of disk. See [Install the server](admin/install.md).

**Do I need a domain?** Not for a test on your own network; phones should use HTTPS on the internet. See [HTTPS and your own domain](admin/https-and-domain.md).

**How do I update?** Run the update script on the server; phones can update later because the server supports the last five app versions. See [Updating the server](admin/updates.md).

**How do I back up?** See [Backups and restore](admin/backups.md). Do this before your first update.

**Something is wrong.** See [Troubleshooting](troubleshooting/index.md).
