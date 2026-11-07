# Privacy modes explained

Who can see where you are, who does the work, and what you give up for more privacy, without jargon.

There are two choices. The circle admin picks the circle's **mode** (Normal or Private). Inside a Private circle each person then picks
for themselves whether the server may help. A picture of both is on [Concepts](../concepts.md).

## The two modes

| Mode | In one sentence | Can the server read your position? |
| --- | --- | --- |
| **Normal** (default for new circles) | Your phone sends your position to the server, which does the work and shows it to your circle. | **Yes.** |
| **Private** | Your position is locked on your phone and only the other phones in the circle can unlock it. | **No.** It stores and relays locked data only. |

### Normal

Simple and complete: the server draws the map, works out trips and weekly driving reports, sends arrival
alerts, and feeds the admin web and integrations such as Home Assistant. The server's owner can in principle read
the data, so run the server yourself or trust whoever does. Whether a *server admin* may look at members on the admin map is a separate
switch that is **off by default** (`ADMIN_LOCATION_ACCESS`); every look is written to an audit log the circle can read.

### Private

Positions are encrypted on your phone with a key the server never has. Other members' phones unlock them. A stolen database or a curious
operator sees only unreadable data and metadata (that something was uploaded, and roughly when).

What changes: the server cannot compute anything from your data, so your phone does it. Phone-side driving reports are an
opt-in switch (off by default) and use more battery. The admin web can show a Private circle only if the signed-in person is a member and has
approved the browser from their phone.

## Private circles: use the server, or keep it on your phone

When the circle admin turns server help on, each member sees a one-time question on their own phone:

- **Use the server (recommended).** Your phone also gives the server a readable copy of **your** data. Reports, history, the admin web
  and integrations work for you. Everyone else keeps sharing locked data.
- **Keep on my phone.** Your data stays locked. No server-made reports unless you turn on phone reports.

Nobody can choose for you, an admin cannot switch you on, and you can change your mind at any time. If you leave the server option, the server stops
receiving new data and the app can delete copies the server already holds.

![Server processing: who uses the server and who keeps data on the phone](../images/app/processing.png)

## Who decides what

- The **circle admin** decides whether server help is offered in the circle, and the default for new people.
  ![Circle processing setting](../images/app/processing-policy.png)
- **Each person** decides for themselves, on their own phone.
- If you are also in a **Normal** circle, that circle still sends your position to the server. Your choice applies per Private circle, and the screen tells you.
- A Private circle shows people missing because their app is old? A circle admin can **switch the circle to Normal** in one tap, so everyone shows up again.
  The server then keeps readable locations for that circle, and the screen explains what is deleted and who is told.

## What a choice does not hide

- That you are using the app and roughly when (the server sees that data was uploaded, its size and time).
- Anything already copied before you changed your mind, and old backups.
- Other members: a member who holds the circle key can read what the circle shares. Only add people you trust.

## Chat, sharing links and SOS

Chat in a Private circle is end-to-end encrypted and the server never reads it (see [Chat](chat.md)). In a Normal circle chat is stored readable on the server.
Share links are for anyone with the link, until they expire. SOS messages work in every mode; see [Safety](safety-and-check-ins.md).

## How to choose

- Server run by you at home and you want every feature: **Normal**.
- Server rented from a hosting company, or someone in the family needs real privacy: **Private**, and accept the battery cost for anyone who chooses **Keep on my phone**.
- Not sure? Start with Normal. You can switch later, and each Private-circle member can still pick what is right for them.
- Technical background: [Privacy processing design](../design/PRIVACY_PROCESSING.md) and [Operator privacy controls](../privacy-controls.md).
