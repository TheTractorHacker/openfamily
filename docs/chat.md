# Family chat

Per-circle text chat. Every circle member can read and post; nobody else can
(a non-member gets 404, the same as an unknown circle).

## API

| Endpoint | Purpose |
|---|---|
| `GET /circles/{id}/chat?before=<seq>&limit=<n>` | Newest-first page (default 50, max 100). `next_before` is the cursor for the next older page, `null` at the start of history. |
| `POST /circles/{id}/chat` `{"body": "..."}` | Send. Returns 201 with the stored message. |
| `POST /circles/{id}/chat/read` `{"seq": n}` | Mark read up to `seq` (omit for newest). Clamped to the newest message; never moves backwards. |
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
