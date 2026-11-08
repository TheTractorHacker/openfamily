# Bubbles

A Bubble is a temporary, per-person geofence modelled on Life360's "Create
Bubble". From a member's profile you tap **Create Bubble**, size a circle
around where that person is right now with a slider, pick how long it lasts
(1 hour, 4 hours, until tonight, 24 hours), and confirm. You are alerted when
they leave the circle (optionally also when they come back). It then expires and
is deleted server-side.

## API

All routes need a signed-in user.

| Route | Effect |
|---|---|
| `POST /bubbles` `{subject_id, radius_m, duration_minutes, notify_reenter}` | Creates a Bubble. `radius_m` 50-5000, `duration_minutes` 15-1440. 201 with the Bubble |
| `GET /bubbles` | `{"bubbles": [...], "about_me": [...]}`: your active Bubbles (with the circle) and the active ones other people drew around you (creator and expiry only) |
| `DELETE /bubbles/{id}` | Cancels a Bubble. Creator only; anyone else gets 404 |

Errors: 400 bad input (including a Bubble on yourself), 404 subject is not a
circle co-member who is sharing with you right now (one uniform answer, so
membership and pauses cannot be probed), 409 the subject has no position newer
than 30 minutes, 429 more than 10 active Bubbles.

Creating a second Bubble on the same person replaces the first.

## Privacy rules

- The creator and subject must share a circle in which the subject currently
  shares their location (`circles.SharedWith`: sharing on, no pause). A person
  who has paused sharing cannot be bubbled.
- The centre is the subject's last server-side position. The client never
  supplies coordinates, so a Bubble cannot be used to probe a place.
- The subject is told. On creation they get a push "A family member created a
  Bubble around you until HH:MM" (the creator's name only with `VERBOSE_PUSH`,
  like every other push; time in the zone they set for quiet hours, else UTC),
  and `GET /bubbles` lists it under `about_me`. They never receive coordinates
  or the radius, and cannot see the circle on a map. The circle is returned
  only to the creator and drawn only on the creator's map.
- The subject cannot cancel it; the control they have is the one they already
  have: pausing or switching off sharing. While paused (or not sharing with the
  creator) a Bubble is not evaluated at all: no alert and no state change, so
  nothing about their movement leaks.
- Push payloads never contain coordinates.

## Evaluation

`evaluateBubbles` runs at the top of `evaluateGeofences`, so it sees every
stored point (ingest, batch upload, and the 60 s reconcile loop that re-checks
each active user's latest point). A Bubble starts "inside". Leaving is crossing
the radius; coming back is crossing 90% of it, so a fix jittering on the edge
does not flap. A transition is claimed with a conditional `UPDATE`, so two
concurrent evaluations of one point alert once, and re-evaluating the same
point is a no-op. Points older than the Bubble itself are ignored.

An alert goes to the creator only: a `{"type":"bubble","event":"left|entered",
"bubble_id","user_id","name"}` WebSocket frame and a push through the shared
`pushUsers` pipeline (direct, UnifiedPush, APNs). Bubble alerts are not rows in
`alerts` (that table is for SOS/help/check-in and has no recipient-delivery
semantics for this), so they have no `alert_deliveries` tracking.

## Expiry

Reads ignore rows past `expires_at`. They are deleted by the geofence reconcile
loop (`purgeExpiredBubbles`, every minute) and by `purgeExpiredSharing` on
create.

## Storage

Migration `000113_bubbles`: table `bubbles` (`circle_id`, `creator_id`,
`subject_id`, `lat`, `lon`, `radius_m`, `notify_reenter`, `expires_at`,
`last_inside`, `last_event_at`, `created_at`); rows cascade when the circle or
either user is deleted.
