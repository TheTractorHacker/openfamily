# Multi-circle data model (GAP-001, GAP-002)

Status: stage 1 implemented on `feat/circles`. Stage 2 is listed at the end.

Goal: a user can belong to several circles (family, friends, ...), is admin in
some and member in others, and chooses per circle whether their location is
shared. The change is additive: `families`, `users.family_id`, `users.role`
and every existing endpoint keep working unchanged for current clients.

## Tables (migrations 000060, 000061)

- `circles(id, name, icon, created_by, created_at)`
- `circle_members(circle_id, user_id, role admin|member, sharing_enabled default true, joined_at)`, primary key `(circle_id, user_id)`, cascades from both parents, index on `user_id`.
- `invite_codes.circle_id` (nullable FK, cascade). `family_id` is now nullable; a CHECK requires one of the two.

### How existing families map

Each `families` row becomes one circle with the **same id** (name, created_at
copied; `created_by` = oldest admin). Each user with a `family_id` becomes a
member of the circle with that id (`admin` stays admin, `member` and `child`
become `member`). Nothing that references `families(id)` (places, geofences,
alerts, audit_log, invite_codes) is rewritten. The backfill uses
`ON CONFLICT DO NOTHING`, so re-running is safe; the down migration drops the
two tables and triggers and loses nothing legacy.

### Staying in sync with legacy write paths

`users.family_id` remains the user's **primary circle** and the legacy
endpoints still read it and `users.role`. Triggers keep the new tables correct
without touching the legacy handlers (or other teams' code):

- `families` insert/rename/delete -> create/rename/delete the circle with that id.
- `users` insert/update of `family_id` or `role` -> upsert/delete the membership of circle `family_id` (self-heals a missing circle).

In the other direction the circle endpoints repair the legacy pointer: removing
a member, leaving, or deleting a circle moves `users.family_id` to the user's
next family-backed circle (or NULL), and a role change in a user's primary
circle also sets `users.role` (a legacy `child` stays `child`). So a removed
member loses legacy access in the same transaction. Circles created with
`POST /circles` have no `families` row; they are reachable only through circle
endpoints (stage 2 will add circle-scoped places/chat to them).

## Roles and consent

Circle role: `admin` (rename, invite, remove members, change roles, delete) or
`member`. The last admin cannot leave, be removed or be demoted (409), checked
inside a transaction holding the circle row lock.

Sharing consent is per membership: `circle_members.sharing_enabled`. A member
changes only their own flag with `PUT /circles/{id}/sharing {"enabled": bool}`;
no admin can turn it on for someone else. The flag is read from the database
for every live update, so turning it off stops the next update for that circle
immediately. A viewer sees subject S's location only through a circle where
both are members **and** S has sharing on. A user always sees themselves.
S still appears in member lists with null location fields (wire format
unchanged).

## The authorization helper (`internal/circles`)

Handlers must not compare `users.family_id` or write membership SQL; they call:

- `RequireMember(ctx, userID, circleID)` -> membership or `ErrNotFound`.
- `RequireAdmin(ctx, userID, circleID)` -> `ErrNotFound` for outsiders, `ErrForbidden` for members.
- `SharedWith(ctx, viewer, subject)` -> circle ids where both are members and the subject shares (self: all own circles).
- `SharingCircles(ctx, subject)` -> circles the subject currently shares in (live fan-out).
- `LocationVisibility(ctx, viewer, circleIDs)` -> co-members and whether their location may be shown.
- `CircleIDs(ctx, user)`.

`New(pool_or_tx)`: works inside a transaction. A non-member and a non-existent
or malformed circle id are indistinguishable (`ErrNotFound`, HTTP 404), so ids
cannot be probed (IDOR / SEC-006). Platform-admin cross-family views are a
separate, audited path and are unchanged.

## Endpoints (handlers/circles.go)

`POST /circles`, `GET /circles`, `PATCH /circles/{id}`, `DELETE /circles/{id}`,
`GET /circles/{id}/members`, `DELETE /circles/{id}/members/{user_id}` (`me` allowed),
`PATCH /circles/{id}/members/{user_id}`, `PUT /circles/{id}/sharing`,
`POST|GET /circles/{id}/invites`, `DELETE /circles/{id}/invites/{invite_id}`,
`POST /circles/join {code}`. At most 25 circles per user.

Choices: `DELETE /circles/{id}` is refused with 409 if it is the only circle of
any member, unless `?force=true`; it never deletes the legacy `families` row or
its places/geofences. Invites reuse `invite_codes`; for a family-backed circle
`family_id` is also set, so the code still works in legacy join/register. A
code for a non-family circle is rejected by the legacy flow (not consumed) and
only redeemable via `POST /circles/join`. Invite roles are admin or member.

## Live read path

The hub keeps its maps but a socket now subscribes to **all** of its user's
circles (`registerCircles`). `broadcastLocation`/`broadcastPresence` fan out to
`SharingCircles(owner)` plus the owner's own sockets, once per socket. Removal,
leave, circle delete and join call `subscribeUser`/`unsubscribeUser` so the
socket set changes at once; the existing 30 s revalidation also re-syncs
subscriptions from the database as a backstop and closes a socket whose user has
no circle. `members` snapshot (WebSocket) and `GET /family/members` use
`LocationVisibility` and blank location fields for non-sharing members. For a
user with one circle and default sharing, output is identical to before.

## Stage 1 limitations

- `child` is not a circle role (maps to `member`); `users.role` stays authoritative for legacy checks.
- A multi-circle user's WebSocket `members` snapshot is the union of their circles (no circle id on the wire yet).
- Account deletion can leave a circle without an admin (promote the oldest member in stage 2).
- The legacy registration flow cannot redeem codes of non-family circles.

## Stage 2 (not done) - exact files

Convert from `family_id` to a circle id taken from the request and checked with `internal/circles`:

- `handlers/place.go` (List/Create/Update/Delete place + admin list), `handlers/geofence.go`, `handlers/geofence_eval.go` (+ migration relaxing `places.family_id` / `geofences.family_id` FK to `circles`, adding `circle_id`).
- `handlers/history.go` (`GetMemberHistory` still checks same `family_id`, ignores sharing), `handlers/location_request.go` (family check, sharing), `handlers/family.go` `GetFamilyMemberAvatar`, `ws.go` `broadcastAvatarUpdate`.
- `handlers/alerts.go`, `handlers/contacts.go`, `handlers/audit.go` (family-scoped fan-out and audit view).
- `handlers/admin.go`, `admin_users.go`, `admin_ws.go` (move/assign/delete family must call circle repair).
- `handlers/auth.go` Register / `invites.go` `consumeInviteCode` (circle invite at registration), `profile.go` DeleteMe (last-admin handling).
- Add circle id to WebSocket frames, tracking history retention per circle, chat (GAP-005), notification settings (GAP-006).
