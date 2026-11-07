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

**Normal circles.** Chat is stored as plain text on your Orbitly server, as
described above. Push text is content-free unless the recipient opted in.
Removed members lose read, post and photo access immediately; deleting a
message removes it from the database (backups age out per retention).

**Private (end-to-end encrypted) circles.** Chat is encrypted on the sender's
phone and can only be opened on the phones of people in the circle. The server
relays scrambled data it cannot read, and never gives the chat key to the
server's own processing helper, even for members who chose "server processing"
for their location. Full design: `design/E2EE_CHAT.md`.

What that means in practice:

* The chat screen shows "Encrypted. Only people in this circle can read this."
* Messages, edits, deletes and photos all work as before. Photos are encrypted
  with their own key before upload.
* Sending works offline: messages wait on your phone and go out later. A
  message that could not be delivered says "Not sent. Tap to try again."
* Notifications are made on your phone after it decrypts the message. The server
  only wakes your phone ("something is waiting"); it never carries message text
  or even who wrote it. If your phone is switched off or the system delays the
  wake-up, you see the message when you next open the app.
* The server still knows that a message was sent, from which phone (so which
  person), when (to the minute) and a rough size. It cannot tell a message from
  an edit or a delete, and it cannot read anything inside.
* The unread badge is counted on your phone. The server's own count (used only
  as a fallback) can be a little high because it cannot tell edits from messages.
* Only the author can edit a message. The author or a circle admin can delete
  it; every phone checks this itself.
* The server keeps the encrypted copies for 30 days (the server owner can change
  this with `E2EE_CHAT_TTL_DAYS`, 1 to 365). Your phone keeps its own history
  (the last 5000 messages per circle), so older chat stays on phones that
  already had it. A reinstalled or new phone can only restore what is still on
  the server.
* People who leave the circle cannot read anything sent after they left.
  A newly joined person can read recent messages still stored on the server
  (up to 30 days) that were sealed with the key they received. Ask an admin to
  make a new circle key before inviting if that matters.
* A family member whose app is too old cannot read or send encrypted chat; the
  chat screen says "<name> needs to update Orbitly to read encrypted chat."
  and an old app that tries to send gets the message "Chat in this circle is
  end-to-end encrypted. Update Orbitly to send and read new messages."

**When a circle turns private.** Messages written before that stay on the
server as readable text. They remain visible, marked "Sent before encryption".
A circle admin can remove them for good with "Delete them" in the chat banner
(`DELETE /circles/{id}/chat/history`).

API additions: `409 {"code":"chat_encrypted"}` for plaintext send, edit and
photo in a private circle; `POST /circles/{id}/chat/read {"item_id": n}`;
`DELETE /circles/{id}/chat/history` (admin);
`POST /circles/{id}/e2ee/blobs`, `GET /circles/{id}/e2ee/blobs/{id}` for
encrypted photos; `GET /circles/{id}/chat` answers `"encrypted": true` for a
private circle (the list is then only the old plaintext history).

## Not supported

Reactions, typing indicators, per-message location sharing. In normal circles
offline queueing of unsent messages across app restarts (the draft survives only
while the screen is open) and a deletion missed while offline is corrected the
next time the chat is opened. In private circles read receipts ("Seen by") are
not available, and sending a photo needs a connection (the text of a message
does not).
