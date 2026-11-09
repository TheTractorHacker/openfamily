# Web access from any browser

See your Private circles in the admin web from **any** browser, the way a password manager opens its vault: sign in, then unlock with a vault passphrase. Nothing is tied to one computer.

Who can use it: **server admins** (platform admins). It is on by default, but nothing happens until an admin sets it up.

## How it works, in plain words

- You approve **one** web viewer key with your phone, once (the same pairing as before).
- The browser seals that key with a **vault passphrase** that only you know and stores the sealed key on the server. The server cannot open it: it never sees the passphrase or the key.
- In any browser: sign in, open **Private circles**, enter your account password (and two-factor code), then the vault passphrase. The key is opened **in that tab only**.
- It locks again when you close or reload the tab, sign out, or after **30 minutes** without activity.
- Your phones get a notification the first time a browser unlocks it.

Members who let the server help (server processing) are on the normal map anyway, before you unlock. Unlocking adds the members who keep their data on their phone.

## Set it up

1. In the admin web, open **Private circles** and press **Set up web access**.
2. Press **Show request code**, copy it, and on your phone open the Private circle, **Approve a viewer or bridge**, paste it, compare the digits, approve.
3. Paste the approval code back into the browser and press **Register viewer**.
4. Choose a **vault passphrase** (at least 12 characters, a few unrelated words work well, **not** your account password), confirm with your account password and two-factor code, press **Save web access**.
5. Your phone shares the circle keys with the new key the next time you open the circle's encryption screen.

## Unlock somewhere else

Sign in, open **Private circles**, fill in the vault passphrase, account password and two-factor code, press **Unlock**. It takes a few seconds on purpose (the passphrase is made slow to guess). The map header shows **Private circles unlocked** with a **Lock** button.

## Change, forget, revoke

| You want to | Do this |
| --- | --- |
| Change the vault passphrase | Unlock, then **Change vault passphrase**. If you think the old one leaked, revoke instead: someone may have copied the old sealed key. |
| Forgot the vault passphrase | On your phone revoke the web viewer, then set web access up again. Your recovery phrase is never typed into a browser. |
| Stop it for good | Revoke the web viewer on your phone (or **Revoke this viewer** while unlocked). The stored sealed key is deleted with it; a circle admin's phone publishes a new circle key. |
| Remove only the stored copy | **Settings > Security > Web access from any browser > Remove web access**, then revoke the viewer on your phone. |

A password reset does not unlock anything: whoever resets your password still needs the vault passphrase.

## For the server operator

- **Off switch.** Untick **Settings > Security > Allow web access from any browser**, or set `E2EE_VIEWER_VAULT=off` in `.env` and restart. Stored sealed keys stay, unusable, until their owners remove them.
- **The pepper file.** The server mixes a secret file into every vault, so a stolen database alone is not enough to start guessing passphrases. It is created on first start at `/data/server-device/viewer-vault-pepper` (the `server_device` volume) or at `E2EE_VIEWER_VAULT_PEPPER_FILE`. Database backups do not include it.
  - **Back it up separately** from the database backups, for example `docker compose cp api:/data/server-device/viewer-vault-pepper ./viewer-vault-pepper` into your password manager or another disk.
  - If it is lost (a restore without the volume), stored web access cannot be opened; the page says so and the admin sets it up again from the phone.
  - Keeping it in the same backup as the database removes its protection.
- **Audit log** entries: `e2ee.viewer_vault_saved`, `e2ee.viewer_vault_opened`, `e2ee.viewer_vault_new_browser`, `e2ee.viewer_vault_deleted`, `admin.e2ee_viewer_vault_changed`.

## What it protects and what it does not

- A stolen database or backup: only sealed data, and guessing needs the pepper file too.
- A stolen session or a stolen password alone: not enough, the vault passphrase is still needed.
- **A weak vault passphrase plus a stolen database and pepper file** can be guessed offline and then reads the Private circles. Use a long passphrase.
- Like any browser viewer, it trusts the web page code the server sends. If you do not trust the server's operator, use the phone app only.

Design and threat model: [Web viewer from any browser](../design/WEB_VIEWER_ANYWHERE.md).
