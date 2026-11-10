# Reinstalling Orbitly

Your phone has its own encryption key for Private circles. Since app version
0.26.28 the app keeps a sealed copy of that key in a place that stays when you
delete the app. When you install Orbitly again and sign in to the **same
account**, the key comes back by itself: no recovery phrase, no approval from
another member, and your circles keep working as before. On a new phone
restored from your Google (Android) or encrypted iPhone backup it works the
same way, with the limits below.

## The honest trade-off

A copy of your phone's key now exists outside the app. Where it sits:

- **Android:** in Google Play services (Block Store). When your phone has a
  screen lock, Google also stores it **in your Google account**, end-to-end
  encrypted, so it can reach a new phone. That means **Google holds an
  encrypted copy** of the key, which only your devices can open. Without a
  screen lock Google does not upload it; it stays on the phone. Orbitly
  cannot see which of the two applies.
- **iPhone:** in the iPhone's keychain, which stays when an app is deleted. It
  is **not** synced through iCloud Keychain. It is carried into an encrypted
  iPhone backup and so can reach a restored iPhone.

If you do not want any copy outside the app, turn the setting off (below). The
price is the old behaviour: deleting the app deletes the key.

## What you need

- **Android:** Google backup on (Settings, Google, Backup) for the copy to
  survive an uninstall, and a screen lock for it to reach a new phone. The app
  must come from the same source as before (Google Play or the same signed
  file): Google only gives the copy to the same app signature.
- **iPhone:** nothing for a reinstall on the same iPhone. A new iPhone gets it
  from an **encrypted** backup.
- The setting **Settings, Security, Keep this phone's key safe through
  reinstalls** must be on. It is on unless you turned it off.

## When the key does not come back

If the Settings row says that this phone cannot keep a copy (for example a phone
without Google Play services), nothing is stored and you set up encryption
again after a reinstall.

The app only brings the key back when the server still lists this phone's key
as active for your account and the key matches exactly. It starts a new key
instead (and you need your recovery phrase or another phone to get your circles
back, as before) when:

- you or another of your phones used **Reset my keys**, or the key was revoked
  (for example "my phone was lost");
- you deleted your keys on purpose (that also removes the copy; if the removal
  fails, the app repeats it and does not use the copy meanwhile). **Set this phone
  up again**, offered when the stored key cannot be read, keeps the copy: the same
  key comes back if the server still lists it;
- you turned the setting off before uninstalling;
- the copy never reached this phone (Google backup was off, no screen lock for a
  new phone, a different app signature, a non-encrypted iPhone backup, or no
  Google Play services).

**Old phone and new phone share one key.** If you restore a copy onto a new
phone while the old phone still has Orbitly, both phones use the same key. If the
old phone is lost, use **Revoke** for it: that also stops the new phone, which
then makes a new key. Sign out and remove Orbitly from a phone you give away.

Someone else signing in to Orbitly on your phone does not get your key and does
not delete it. When you sign back in, it is still there.

## Turning it off

Settings, Security, **Keep this phone's key safe through reinstalls**. Turning
it off deletes the copy at once. The key then lives only inside the app, and
deleting the app deletes it. Keep your
[recovery phrase](members-and-devices.md#encryption-keys) written down either way.

## What the copy contains

Only what is needed to recreate this phone's key: the 32-byte key seed, this
phone's device id and your account id, with a version byte, sealed
(XChaCha20-Poly1305). Your circle keys are not in it; the phone fetches them
again from the server, where they wait encrypted for this phone. The technical
details and the trade-offs are in the
[E2EE design](../design/E2EE.md#keys-survive-a-reinstall).
