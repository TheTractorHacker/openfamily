# Removing a member, devices and lost phones

Remove someone from a circle, sign out a lost or replaced phone, and what each person can do with their own devices.

## Remove a person from a circle

Circle admins: open the circle, tap the person, choose **Remove**. They lose the
map, chat and photos immediately. In a **Private** circle the circle key is
renewed so a removed person's phone cannot read anything new.

## Someone left or changed phone

Ask them to sign in on the new phone. For a Private circle the new phone must
be approved by one of their other devices, or recovered with their recovery key.
Remove the old phone from **Settings, Security, Active sessions**.
If they had neither (they chose **Set this phone up again**), a circle admin
approves the new phone in **Encryption keys**, after comparing safety numbers.

![Security: sessions, password, two-step sign-in](../images/app/security.png)

## Encryption keys

**Settings, Security, Encryption keys** shows, at the top, whether this phone's keys are safe, then the two
everyday actions: **Recovery phrase** (24 words to get your circles back) and **Link another phone**. Below
that is one row per circle with its status (Private or Normal); tap a circle to see its members, compare
safety numbers and approve a new phone. The technical details (fingerprint, where the key is stored, a check
of the server record) are under **Advanced**.

![Encryption keys: key status, recovery phrase, link another phone, the circle list and Advanced](../images/app/encryption-keys.png)

Deleting and reinstalling the app keeps your key: see
[Reinstalling Orbitly](reinstalling.md).

## Owner approval (when you are the only admin)

If you created a Private circle, are its only admin and set your own phone up
again, nobody else can approve it. The circle screen in **Encryption keys**
then offers two ways out: make another member an admin (**Members**), or turn
on **Owner approval** for that circle and tap **Approve as owner**. Both steps
ask for your password (and your two-step code if you use one). Everyone in the
circle is told, and your key is shown as "approved by the owner without a
second admin".

This trades a little security for recoverability: someone who steals your
password (and two-step code) could do the same with a phone of their own. Keep
it off unless you need it, keep your recovery phrase (restoring with it needs no
approval), and make a second member an admin. Any admin can turn it off again.

## Lost or stolen phone

1. Sign in on another device and open **Security, Active sessions**; sign the
   lost phone out. Change your password.
2. Ask your server admin to revoke the session on the admin web **Audit and
   sessions** page if you cannot.
3. Turn on two-step sign-in so a stolen password alone is not enough.
4. If the phone held a Private circle key, a circle admin should remove and
   re-add you so the key is renewed.

## Leaving for good

**Settings, Delete my account** removes your account and data; **Download my
data** exports a copy first.
