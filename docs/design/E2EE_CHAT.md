# Encrypted chat (design and status)

Family chat in a Private circle is sealed on the sender's phone and opened on the
members' phones. The server relays ciphertext only. Chat is never processed by
the server: it is sealed under the phone key line (`CK`) only, never wrapped to
the server device, never read by the sidecar, even when a member's processing
lane is `server` (PRIVACY_PROCESSING.md, key lines and lanes).

Code: server `backend/internal/handlers/e2ee_channel.go`, `chat.go`,
`e2ee_chat_blob.go`, migration `000250_chat_e2ee`; app
`app/lib/services/chat/` and `app/lib/services/e2ee/private_*.dart`.

## 1. Decision: a purpose on the existing relay

Chat is the channel purpose `chat` on the `e2ee_items` relay (the purpose was
reserved from the start, bucket now 8192). Reasons: ordering by relay id,
idempotency by `(circle, device, seq)`, TTL, acknowledgement-free pull with a
cursor, the WebSocket `e2ee_item` frame, the silent wake-up push, the key
epoch/rollback rules and the sender signature all exist and are tested. A
separate table would duplicate all of it. The cost is that edits and deletes are
items too (the server cannot tell a message from an edit), see "unread".

Item format is the existing v1 phone-line item: `AEAD(CK epoch key)` over the
padded envelope `1 || seq || ts || Ed25519 signature of the sender device || body`.
The signature covers circle, epoch, device, purpose, seq, time and body. The
`body` is JSON (below). Nothing about chat is new cryptography.

## 2. Message types (the sealed JSON `body`)

| `k` | Fields | Meaning |
|---|---|---|
| `msg` | `id` (client uuid), `t` text (1 to 2000 chars), optional `img` | A message. The message key is `(author, id)`; the author is the VERIFIED owner of the signing device, never a field in the JSON. |
| `edit` | `id`, `t` | Replaces the text of the SENDER's own message `id`. Version = the item's signed time, then relay id. |
| `del` | `id`, `a` (author user id) | Tombstone. Honoured when the signer is the author (`a` equals the signer) or a CURRENT circle admin. |
| `read` | not implemented | Read markers inside the encrypted stream are out of scope (see "metadata"). |

Reactions and typing indicators do not exist in plaintext chat either, so they
are not added.

**Attachments (photos).** Plaintext chat has photos, so encrypted chat has them:
the phone re-encodes the image (EXIF dropped, 5 MiB limit), encrypts it with a
fresh random 32 byte key (XChaCha20-Poly1305, 24 byte nonce, format
`0x01 || nonce || ct || tag`, AAD `"OFE2EE3-BLOB\0" || circle_id`) and uploads
the bytes with `POST /circles/{id}/e2ee/blobs` (an opaque row in `e2ee_blobs`,
members only, circle bound, expires with the chat). The message carries
`img = {b: blob id, k: base64 key, m: mime, s: size}`. The key is therefore
only inside the sealed message. A blob the server holds is just random bytes.

## 3. Authentication, replay, edit and delete authorization

* **Who sent it.** The signature is by the sender's device key; the receiver
  maps the device to a person through the verified key log and the member list.
  A member who shares `CK` still cannot post "as" someone else.
* **Duplicates and replay.** The receiver's per-device window drops a repeated
  `(device, seq)`; the store is idempotent by `(author, id)`; the relay
  deduplicates on `(circle, device, seq)`. A replayed old `edit` cannot revert a
  newer one (an edit applies only if its `(signed time, relay id)` is newer than
  the one already applied). Wrong circle or wrong epoch fails the AEAD or the
  signature. A tampered byte fails the AEAD.
* **Edit.** Only the author's own `(author, id)` can be edited: an `edit` from
  anyone else addresses `(signer, id)` and so touches nothing of the author's.
* **Delete.** The author may delete their own message. A circle admin may delete
  anyone's: the `del` carries `a`, and a receiver honours it only if the signer
  is `a` or an admin in its CURRENT member list. This is the same rule the
  plaintext server enforces ("sender or admin"). It is enforced by every client,
  not by the server (the server cannot read it). A forged tombstone from a
  non-admin is ignored. A tombstone that arrives before its message is kept and
  suppresses the message when it arrives; a deleted message is removed from the
  phone's store (only a tombstone stays).
* **Honest limit.** A deletion removes the message from phones that receive the
  tombstone. A phone that was offline for longer than the relay keeps tombstones
  (30 days) shows the message until it is deleted by hand; a phone that already
  copied the text can of course keep it.

## 4. Who can read what: epochs, joining, removal

* Chat uses the circle key epoch exactly as locations do. A member removed from
  the circle triggers a new epoch which is never wrapped to them: they cannot
  open any message sealed after the removal, and they lose relay access at once.
* **New member.** A new member receives the current epoch key. They can read
  chat sealed under that epoch that is still on the relay (up to the TTL), then
  everything new. Messages sealed under older epochs are not readable (they hold
  no key for them). An admin who wants a strict "only after joining" cut makes a
  new epoch (the existing "new key" action) before inviting. This is a property
  of the epoch model, not something the chat layer can add.
* **New phone of an existing member.** An approved new device gets the epoch
  wraps the existing device or the recovery key wraps to it, and then replays
  the relay (cursor 0) so it recovers up to the TTL of chat. Older history is
  not on the server; it is only on phones that already had it. There is no
  phone-to-phone history transfer in this release.
* **Retention.** The relay deletes chat ciphertext after 30 days
  (`E2EE_CHAT_TTL_DAYS`, 1 to 365; longer than the 48 h of live locations).
  Phones keep their own history locally (last 5000 messages per circle).
  Attachments expire a day after the chat TTL.
* The phone store is not backed up to the cloud; a reinstall loses history older
  than the relay window.

## 5. What the server still sees (metadata)

The server sees: that a chat item exists, the circle, the sending DEVICE (and
so, from its key records, the person), the minute it arrived, and a size bucket
(256 .. 8192 bytes), and that someone uploaded an attachment of a given size.
It does not see text, edits, deletes, attachment content, who deleted what, or
whether an item is a message, an edit or a delete. It sees which chat item id
each member has marked as read in the server cursor (only to compute the
badge, below).

## 6. Server rules

* `chat` is accepted on `key_line = 'phone'` only. Handler code `chat_phone_only`,
  a CHECK constraint (`e2ee_items_chat_phone_only`) and the `e2ee_item_guard`
  trigger reject anything else. `e2ee_purge_user_server_copies` therefore never
  has chat to delete.
* A `required_server` circle does not block chat from a member who has not
  signed the server lane (like check-ins and events, chat is exempt).
* The sidecar/bridge pulls `purpose=fix,history` on the server line only and
  discards every other purpose; the pull with a server-kind device is forced to
  the server line. Tests assert that no chat is served to it.
* **Plaintext chat in a private circle.** `POST /circles/{id}/chat`, `PATCH`
  and the photo upload answer `409 {"code":"chat_encrypted"}` with the text
  "Chat in this circle is end-to-end encrypted. Update OpenFamily to send and
  read new messages." An old app shows that message. A database trigger
  (`chat_plaintext_guard`) refuses plaintext rows in a private circle as a
  backstop. Non-private circles are unchanged. Listing and deleting old
  plaintext stay available.
* **Old history.** Messages written before the circle turned private stay in
  `chat_messages` and `GET /circles/{id}/chat` still lists them with
  `"encrypted": true` on the response; the app shows them under a divider
  "Sent before encryption" and marks them. A circle admin can erase them with
  `DELETE /circles/{id}/chat/history` (audit-logged `chat.history_deleted`); the
  app offers this as "Delete old unencrypted messages".
* **Unread badge from metadata.** `GET /chat/unread` adds, per circle, the count of
  chat items from OTHER people's devices with id after the caller's server
  cursor. The cursor moves with `POST /circles/{id}/chat/read {"item_id": n}`
  (clamped to the newest chat item, never moves back). The server count includes
  edits and deletes (it cannot tell them apart), so it can be too high. The app
  therefore shows its own exact count (decrypted messages from others newer than
  the local read position) and uses the server count only as a fallback.
* **Live.** The batch handler broadcasts the existing `e2ee_item` frame (cipher
  only) and a silent `e2ee_wake` data push (rate limit 1 per circle per 2 s for
  chat). It contains no text and no name.

## 7. Notifications

For a Private circle the server sends no visible chat push and no text. The
wake-up push is silent; the receiving phone pulls, decrypts and raises the
notification locally ("<name>: <text>", or "<name> sent a photo"). Wake-ups are
best effort (on iOS the OS may delay or drop a silent push); the unread badge and
the open chat catch up on every app open, resume and socket reconnect. A circle
may mute a person as before.

## 8. App behaviour

* Chat screen is shared; a repository (`ChatService`) has a plaintext
  implementation (`ApiChatService`) and an encrypted one (`EncryptedChatService`);
  a router picks per circle by its mode.
* Banner: "Encrypted. Only people in this circle can read this." States: "Waiting
  for the circle key" (no epoch key yet; items are kept and retried after a key
  sync), "<name> needs to update to read encrypted chat" (a member whose phone
  lacks `chat_e2ee`; shown from the member list), "Sent before encryption"
  (old plaintext), "Sending / Not sent. Retry".
* Send: optimistic; sealed immediately and put into the sealed upload queue
  (idempotent by `(circle, device, seq)` and by the message id), retried across
  restarts. Queue facts of PRIVACY_PROCESSING 19.1 apply: two isolates can race
  on the queue in a narrow window, which the queue's own version check and the
  idempotency absorb; the chat store uses the same versioned read-modify-write
  with a read-back check and applies every item idempotently. Messages older than
  the queue's 48 h limit that were never delivered are dropped from the queue
  and shown as "Not sent".
* Receive: live frame, silent wake and catch-up poll all go through the same
  receiver (dedupe window, signature check, rollback rules). A crash between
  "seen" and "stored" can lose one message on that phone (it is still on the relay but
  the receiver treats it as seen); this narrow window is the same as for every
  other purpose.
* Old apps: a member whose app predates this cannot read or send in a Private
  circle's chat (it has always been unable to read Private circle locations
  either); they see the 409 text above.

## 9. Not in this release

Read receipts ("Seen by") in encrypted chat, reactions, typing indicators,
phone-to-phone history transfer for a new device, cloud backup of chat history,
search across circles.
