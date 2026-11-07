# Check-ins and temporary sharing

Three small features that let a person decide, for a limited time, who sees
where they are. OpenFamily still never contacts emergency services (see
[safety.md](safety.md)); none of this changes SOS.

## "I'm here" check-in to chosen people

`POST /checkins` `{recipient_ids, note?, lat?, lon?}`

- Every recipient must share at least one circle with the sender. Anyone else
  (or an unknown id) gives a uniform `404 member not found`.
- Up to 25 recipients, note up to 280 characters, `lat`/`lon` together and in
  range. Sender cooldown is `ALERT_COOLDOWN`.
- Stored in `checkins` / `checkin_recipients` for 30 days (`expires_at`). Reads
  filter on `expires_at > now()`; expired rows are also deleted opportunistically.
- Delivered over the recipients' WebSocket (`{"type":"checkin", ...}`) and push.
  Like other pushes it carries no coordinates and, unless `VERBOSE_PUSH=true`,
  neither the sender's name nor the note.
- `GET /checkins` lists check-ins you received; `?direction=sent` lists yours.
  `limit` 1-100 (default 30).
- A check-in is an explicit act, so it works while sharing is paused.
- Audit entry `checkin.send` (counts only).

This is separate from the family-wide `POST /alerts/check-in`.

## Pause sharing

`PUT /sharing/pause` with exactly one of `{minutes}` or `{until: RFC3339}`
(1 minute to 30 days from now); `GET /sharing/pause`; `DELETE /sharing/pause`
resumes at once. The app offers 1 hour, until tomorrow (07:00 local) and custom.

The pause is folded into every sharing decision in `internal/circles`
(`SharedWith`, `SharingCircles`, `OwnAndSharingCircles`, `LocationVisibility`,
`MemberCircles`), so it is honoured by the members snapshot, the live WebSocket
broadcast and presence frames, `POST /locations/watch` (live boost, which returns
the usual 404) and the trips endpoints. `paused_until > now()` is evaluated in
SQL on each read: a pause ends on time without any job. Setting or clearing a
pause sends the usual `sharing` frame (with `paused`/`paused_until`) to circle-
aware clients; expiry sends no frame, clients pick the pin up on the next
location frame or snapshot.

The phone keeps recording its own history and geofences while paused.
SOS (`/alerts/sos`) does not use these helpers and always shares.
Platform-admin consoles are outside circles and are not affected.

## Live share with one person

`POST /live-shares` `{viewer_id, minutes}` (1 to 1440) shares your last known
position with one circle member until it expires; re-sharing replaces the
expiry. `GET /live-shares` returns `{outgoing, incoming}`; incoming entries carry
the sharer's last position and `recorded_at`, withheld (`paused: true`) while
the sharer's sharing is paused. `DELETE /live-shares/{id}` ends it (either party).

Expiry is checked on every read, and membership is re-checked on read, so
leaving the circle ends the share. Viewers poll `GET /live-shares`; live shares
are not pushed over the WebSocket.
