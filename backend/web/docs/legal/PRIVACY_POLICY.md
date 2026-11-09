# Orbitly Privacy Policy (DRAFT)

What the Orbitly app and a server running Orbitly do with your information, in plain words. DRAFT for the owner to review with a lawyer; this is not legal advice.

> **DRAFT. Not legal advice.** Fill in the three marked placeholders, have a lawyer
> review this text for your country, and remove this box before you publish it.
> Placeholders: **[OPERATOR NAME]**, **[OPERATOR CONTACT EMAIL]**,
> **[LAST UPDATED DATE]**.

Last updated: [LAST UPDATED DATE]

## The short version

- Orbitly is software you run for your own circle (family and friends). **There is
  no Orbitly cloud.** The people who wrote the Orbitly software do not receive your
  location, messages, name or email, and the app contains no advertising, no
  analytics and no crash-reporting service.
- Your information is stored on **the Orbitly server you connect to**. That server
  is run by an administrator you know (often one person in your family), or by an
  organisation, not by the app developer. That administrator is the one responsible
  for your data on that server.
- Orbitly never sells data and never uses it for advertising.

## Who is who

| Role | Who | What they do |
|---|---|---|
| **You** | The person using the app | Choose a server, a circle and what you share |
| **Server operator** | The person or organisation that runs the server you sign in to: **[OPERATOR NAME]** for the demo and review servers, whoever you were invited by for your own circle | Controls the server, its database, its backups and its settings. Decides how long to keep data. Is the "data controller" for the data on that server |
| **App developer** | The publisher of the Orbitly app in the app stores | Builds the app. Receives nothing from your use of it. Apple and Google see standard store information (see "Apple and Google") |

This policy covers the app and the standard server software. A server operator may
add their own rules; ask them. Contact for the demo and review servers:
**[OPERATOR CONTACT EMAIL]**.

## What the server stores

The server stores what is needed to run your circle:

- **Account:** email address, display name, an optional phone number, an optional
  profile photo, your role (admin, member or child) and a salted password hash
  (Argon2id). If you turn on two-step sign-in, its secret is stored with extra
  protection on the server.
- **Devices:** the phone's platform and name, an app version, a push-notification
  address, when it was last online and its battery level.
- **Location (if you share it):** precise coordinates, time, accuracy, speed,
  movement type (walking, driving, still), battery level and whether the phone
  is charging, from your phone, also
  while the app is in the background if you allow "Always" or "Allow all the
  time". The newest position of each person is kept so a person who is offline
  still shows on the map.
- **Places and alerts:** places you or your circle admins create (name, point,
  radius), arrival and departure events, check-ins, SOS and help alerts with their
  notes, and short-lived links created when you share a position.
- **Chat:** messages and photos sent in a circle chat (see "End-to-end encrypted
  circles" for what the server can read).
- **Emergency contacts:** a name and a phone number you enter. These are used only
  if you use the optional text-message (SMS) alert and your server administrator
  switched SMS on.
- **Driving and trips:** if you allow it, trips and driving events (such as hard
  braking or a possible crash) are worked out on your phone or on the server.
- **Security log:** sign-ins, session changes and administrator actions, with
  times and network addresses.

The app itself stores a sign-in token, settings and an offline queue on your phone.
Secrets for end-to-end encrypted circles stay on your phone (on iPhone wrapped by a
key in the Secure Enclave where available) and are not in cloud backups.

## End-to-end encrypted ("Private") circles

A circle is either **Normal** or **Private**.

- In a **Normal** circle, positions, places, alerts and chat are stored readable on
  the server, so the server administrator (and whoever can access that server's
  database or backups) can read them.
- In a **Private** circle, positions, history, places, arrival events, the position
  in check-ins and SOS, chat messages and photos are encrypted on your phone and can
  only be opened on the phones of the circle's members. The server stores and relays
  ciphertext. It still sees *metadata*: who is in which circle, when a phone is
  online, how much it uploads, and network addresses.
- If the server operator turns on the optional "trusted server" mode, and every
  member of a Private circle agrees on their own phone, the server can read that
  circle. The circle is then labelled "Server can read" in the app.
- If you lose every phone and your recovery phrase, encrypted data cannot be
  recovered by anyone.

## Who can see your information

- **Members of your circles**: only what you choose to share with that circle,
  and you can pause or turn off sharing at any time.
- **Server administrators**: they manage accounts. By default they **cannot see
  where people are**; the server operator has a setting that allows it, and
  every such access is written to the security log, which circle admins can see.
- **Emergency contacts**, only when an SOS is sent and optional SMS is switched on.
  The text message carries a link on your own server that expires after 24 hours.
- **Service providers the server may use**, only if the operator configures them:
  - *Map tiles*: your phone loads map images from a tile provider (by default
    OpenStreetMap and Esri). They see the part of the map you look at and your
    network address, not your account.
  - *Address search*: when a place address is typed, the server sends that text (and
    the pin position) to a geocoder (by default Photon, with Nominatim and the US
    Census geocoder as fallbacks). No account details are sent. The operator can
    turn this off.
  - *Push notifications*: Apple Push Notification service on iPhone; your ntfy or
    another UnifiedPush server on Android. Notifications do not contain
    coordinates; by default they do not contain the text of a message.
  - *SMS*: Twilio, if the operator enabled SMS; it sees the destination number and
    the link.
  - *Home Assistant*: only if someone in your circle creates an integration token.
- We do **not** sell, rent or share your information for advertising, and the app
  has no tracking (it declares "no tracking" to Apple).

## Apple and Google

If you install the app from the App Store or Google Play, Apple or Google process
your store account, purchases (there are none), device and crash information under
their own policies. The app developer does not receive your location, messages or
account details from them.

## How long information is kept

- **Location history:** 90 days by default (the server operator may choose a
  different period, and you can shorten it for yourself in the app). Older points
  are deleted automatically.
- **Last known position:** until you delete your account or leave, so an offline
  person still appears on the map.
- **Alerts and share links:** share links expire after 24 hours. Alerts and
  check-ins follow the server's retention settings.
- **Encrypted live data** on the server is held for a short live window
  (48 hours by default) and encrypted history for your retention setting.
- **Security log:** kept by the server operator for as long as they decide.
- **Backups** made by the operator may keep older copies until they rotate out.

## Your choices and rights

- **See and export:** Settings, "Download my data" produces a copy of the data the
  server holds about you.
- **Delete your account:** Settings, "Delete my account" deletes your account and
  its location history, devices, contacts and messages you sent, after you confirm
  with your password. (A circle's last administrator must first hand over
  administration; if you are the only member the circle is dissolved.) The only
  data kept is an append-only encryption key log that holds ids, hashes and
  signatures, not names or positions.
  If you cannot open the app, ask the server operator to delete your account.
  For the demo and review servers write to **[OPERATOR CONTACT EMAIL]**.
- **Stop sharing:** turn off or pause sharing, or leave a circle, at any time.
  Permissions can be changed in the phone's settings.
- **Access, correction, objection, complaint:** depending on where you live (for
  example the EU/UK GDPR or California law) you may have rights over your data.
  Use the in-app tools first, then ask the server operator. You may also complain to
  your data protection authority.

## Children

Orbitly is meant for families and friends, not for children to use alone. A
circle administrator (a parent or guardian) creates and manages "child" accounts.
The operator of the server and the circle administrator are responsible for
having any consent that the law of their country requires. We do not knowingly
collect data from children under 13 for any purpose other than letting their own
circle see them. Children cannot change places, and a parent can remove a child
from a circle at any time. If you think a child's data is on a server without a
parent's consent, contact that server's operator.

## Contacts and photos

The app does **not** read your address book. When you add an emergency contact, the
phone's own contact picker returns only the one number you choose. Photos and
camera: used only if you take or attach a picture for chat or choose a profile
photo; location data inside photos is removed before sending.

## Security

Connections use HTTPS only; the app refuses plain HTTP. Passwords are hashed with
Argon2id, optional two-step sign-in and passkeys are available, sessions can be
revoked, and Private circles are end-to-end encrypted. No system is perfect.

To report a security problem, use the private advisory form on the project's
GitHub page (`SECURITY.md` in the source) or email **[OPERATOR CONTACT EMAIL]**.
Please do not publish details before it is fixed.

## Analytics, advertising and tracking

None. The app and the server software contain no analytics, advertising,
attribution or crash-reporting SDK, and the app does not use an advertising ID.
The project website does not set cookies.

## Where your data is processed

On the server you connect to, in the country where its operator hosts it. If your
operator is in a different country than you, your data is transferred there by your
own choice of server.

## Changes

If this policy changes, the new text is shown at `/privacy` on every Orbitly server
that is updated, and the date above changes. Material changes are announced in the
app's release notes.

## Contact

**[OPERATOR NAME]**, **[OPERATOR CONTACT EMAIL]**
