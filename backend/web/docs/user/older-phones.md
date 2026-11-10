# Orbitly on older phones

How Orbitly adjusts itself to phones with little memory, and which download file to choose.

Orbitly checks how much memory your phone has when it starts and adjusts
itself. You do not have to set anything.

| Your phone | What changes |
|---|---|
| Under 4 GB of memory (many phones sold as 2 GB or 3 GB) | **Lite.** The app keeps a shorter recent trail on the phone, loads updates in smaller steps, draws the map with a smaller picture cache and fewer soft shadows, and never does heavy report calculations on the phone itself. |
| 4 GB up to under 6 GB | **Standard.** Everything works; caches are moderate. |
| 6 GB or more | **Full.** Everything works with the largest caches. |

Nothing you can see is switched off. Older days of history are loaded from the
server when you open them instead of being kept on the phone. In a Private
circle the server cannot read your history, so those phones keep the last
500 points per person (Lite) instead of 6000.

## Which file should I install?

- **`orbitly-<version>.apk`** works on every phone. Use this if you are unsure.
- **`orbitly-<version>-arm64-v8a.apk`** is about 40 percent smaller and fits
  almost every phone made since 2017 with a 64-bit system.
- **`orbitly-<version>-armeabi-v7a.apk`** is for older phones with a 32-bit
  system. Many 2 GB phones are of this kind.

The invite page and the server's download link give you the file that works on
every phone.

## If the app feels slow or gets closed in the background

1. Close apps you are not using.
2. Keep Orbitly set to **Unrestricted** battery use (see
   [Battery and permissions](battery-and-permissions.md)). Phones with little
   memory close background apps sooner; this setting asks the phone to keep
   Orbitly.
3. Restart the phone once if it has been on for weeks.
4. Open **Settings, Advanced, Diagnostics** and send the report if it still struggles.
