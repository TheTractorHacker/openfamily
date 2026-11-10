# Battery, permissions and keeping tracking alive

For the map to stay current, Android and iOS must let Orbitly run in the
background.

![Location access explained](../images/app/permissions.png)

1. Allow location **"All the time"** (not "While using").
2. Allow notifications and, on Android, "Physical activity" for driving.
3. Android: set battery for Orbitly to **Unrestricted** or **Don't optimize**.
   Samsung, Xiaomi and Huawei phones have an extra "sleeping apps" list; remove
   Orbitly from it.
4. Install ntfy (or accept the app's built-in channel) so alerts arrive when the
   app is closed: [Notifications](../admin/notifications.md).

## What costs battery

- Normal use is light.
- **Private circles** and **driving detection** do their calculations on the
  phone. You may see higher battery and CPU use while driving or after a long
  offline period. The app warns you before you turn this on.
- Poor signal, and a "live boost" while someone watches you, use more.

## Self-test

**Settings, Advanced, Diagnostics** (self-test) checks permissions, battery exemptions
and connectivity, and the server can warn the circle when a phone goes silent.
See [Reliability](../reliability.md).

![Settings](../images/app/settings.png)
