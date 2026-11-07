# Family chat

Per-circle text chat. Every circle member can read and post; nobody else can
(a non-member gets 404, the same as an unknown circle).

## API

| Endpoint | Purpose |
|---|---|
| `GET /circles/{id}/chat?before=<seq>&limit=<n>` | Newest-first page (default 50, max 100). `next_before` is the cursor for the next older page, `null` at the start of history. |
| `POST /circles/{id}/chat` `{"body": "..."}` | Send. Returns 201 with the stored message. |
| `POST /circles/{id}/chat/read` `{"seq": n}` | Mark read up to `seq` (omit for newest). Clamped to the newest message; never moves backwards. |
| `GET /circles/{id}/chat?after=<seq>` | Catch-up: only messages newer than `seq` (used after a socket reconnect). |
| `POST /circles/{id}/chat` `{"body", "client_id"?}` | With a `client_id` (max 64 chars) a retry returns the already stored message (200, no duplicate, no second push). |
| `PATCH /circles/{id}/chat/{msgId}` `{"body"}` | Edit your own message (photo captions too). Others get 404. Sets `edited_at`; live `chat_edit` frame. |
| `DELETE /circles/{id}/chat/{msgId}` | Hard-delete (row, text and photo). Sender, or a circle admin (moderation, audit-logged as `chat.delete`). Live `chat_delete` frame. |
| `POST /circles/{id}/chat/photo` | Photo message (JPEG/PNG, 5 MiB, re-encoded to drop EXIF). `GET .../{msgId}/photo` serves it to members only. |
| `GET /chat/unread` | `{"circles": {id: n}, "total": n}`, other people's messages newer than your read marker. |

Limits: body is trimmed, 1 to 2000 characters (413 above that), at most 20
sends per user per minute (429). Messages live in `chat_messages` (migration
000110) and are deleted with their circle or sender.

## Live delivery and push

A send is broadcast as a WebSocket frame
`{"type":"chat","circle_id":...,"message":{...}}` to every socket subscribed to
the circle, over the existing `/ws/stream` hub. Other members' devices also get
a push (direct, UnifiedPush or APNs). The push never carries location data and,
unless `VERBOSE_PUSH=true`, not the message text either: it reads "New message
in <circle>".

## App

The Circle tab has a Family chat row (and the tab icon a badge) showing the
unread count. The chat screen shows the message list, loads older pages on
scroll, and has a composer that refuses empty or over-long text.

Long-press a bubble in the app to edit or delete (admins see delete on any
message). A failed send keeps the draft and retries with the same `client_id`.
The open chat fetches missed messages on every WebSocket reconnect. Sends,
edits and deletes share the 20 per minute limit (migration 000210 adds
`edited_at` and `client_id`).

## Privacy and E2EE

Chat is NOT end-to-end encrypted, including in Private (E2EE) circles: text and
photos are stored in plaintext on the server (see `design/E2EE.md`, channel
`chat` is reserved). Push text is content-free unless the recipient opted in.
Removed members lose read, post and photo access immediately; deleting a
message removes it from the database (backups age out per retention).

## Not supported

Reactions, typing indicators, per-message location sharing, and offline
queueing of unsent messages across app restarts (the draft survives only while
the screen is open). A deletion missed while offline is corrected the next time
the chat is opened.
