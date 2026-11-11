# Battery, permissions and keeping tracking alive

For the map to stay current, Android and iOS must let Orbitly run in the
background. Nothing on this page needs a computer or adb: every check is inside the app.

![Location access explained](../images/app/permissions.png)

1. Allow location **"All the time"** (not "While using").
2. Allow notifications and, on Android, "Physical activity" for driving.
3. Android: set battery for Orbitly to **Unrestricted** (also called **Don't optimize**). Open
   **Settings > Advanced > Keep tracking alive** in Orbitly: it shows what is right and what is not, and each
   row that is not right has a button that goes straight to the place that fixes it. By hand:
   **Settings > Apps > Orbitly > Battery > Unrestricted**.
4. Install ntfy (or accept the app's built-in channel) so alerts arrive when the
   app is closed: [Notifications](../admin/notifications.md).

## Keep tracking alive (Android)

**Settings > Advanced > Keep tracking alive** is a checklist with live answers. It is also what the first-run
"Keep background updates reliable" message and the onboarding "Background updates" button open. It re-checks every time
you come back from a settings page, so you can see a fix take effect.

| Row | What it needs |
| --- | --- |
| Location sharing | Sharing is on in Orbitly. |
| Phone location switch | Location is on for the whole phone. |
| Location permission | **Allow all the time**, not "While using". |
| Battery and background limits | **Unrestricted**, not "Optimized" or "Restricted". |
| Samsung sleep settings (Samsung only) | Green when Android reports Orbitly as Unrestricted. |
| Android's power group | Not "rare" or "restricted" (Android puts an unused app there). |
| Notifications | Allowed (Android may hide the "sharing" notice otherwise). |
| Background tracking service | Running. |
| Orbitly restarting itself | Only shown when it tried; says if Android refused and why. |
| Android stopped Orbitly | Only shown when Android recorded a "Force stop" style end in the last 3 days. |

### Samsung phones

Samsung has an extra list, **Settings > Battery > Background usage limits > Never auto sleeping apps**. You do
**not** need Orbitly on it. If you search it for Orbitly and it says **No apps**, that is expected: Samsung's list can
leave out an app whose battery use is already **Unrestricted**. What counts is
**Settings > Apps > Orbitly > Battery > Unrestricted** (the checklist has a button for it). Then open
**Settings > Battery > Background usage limits** once and make sure Orbitly is **not** under **Sleeping apps** or
**Deep sleeping apps**; if it is, remove it. Orbitly cannot read those two lists, so that one check is yours. Xiaomi and
Huawei phones have similar extra lists.

### What Orbitly does by itself

If Android ends the tracking service while sharing is on, Orbitly tries to start it again when: a movement change is
detected, its 10 minute check fires, the phone's clock or time zone changes, or the server asks the phone for a
position (the server does that when a sharing phone has been quiet for 15 minutes, at most once every 15 minutes,
never while you paused sharing). Android only allows a start from the background in some cases (the clearest one: the
app is **Unrestricted**), so a restart can be refused; the checklist then says so. Orbitly cannot do anything when the
app was **force-stopped** (including by Samsung's sleeping apps): Android sends it nothing until you open it.

## Tracking stopped while the app was closed

Android can end Orbitly's background service on its own (low memory, a battery or "sleeping apps" rule of the phone
maker, a frozen app). Orbitly cannot prevent that. What it does: it tries to start the service again (above), it starts
it again when you open the app if sharing is on and "Allow all the time" is granted, and it keeps a record of what
happened so the next time can be explained.

What to check, in this order:

1. Open **Settings > Advanced > Keep tracking alive** and fix every row that is not green.
2. Sharing is on in Orbitly and the circle is not paused.
3. Open **Settings, Advanced, Diagnostics**, tap **Copy diagnostic report** and look at these lines at the end:
   - **Recent process exits**: Android's own record of why Orbitly's process ended (for example `FREEZER`,
     `LOW_MEMORY`, `USER_REQUESTED`, `CRASH`), with the time in UTC (there is no local time in the report, so convert it). Compare the time
     with the moment the map stopped updating. This needs Android 11 or newer.
   - **standby_bucket** and **battery_optimisation_ignored**: `RESTRICTED` or `RARE`, or `no`, means Android limits
     background work for Orbitly.
   - **Background pipeline**: the last location upload the server accepted, the last identity or encryption error, and counts per hour
     (received, dropped, parked, posted, credential failures, seal errors, heartbeats).
   - **Tracking journal**: service created and destroyed (with whether the stop was requested), app paused and resumed,
     the service restarted on resume, permission changes, heartbeats that could not be delivered because the service
     was gone, `alarm_fired` (the 10 minute check, with a count), `service_restarted_by_watchdog` or `watchdog_refused`
     (Orbitly's own restart attempts and Android's answer), `push_wake`, and `background_drain` lines when positions
     that waited for an unreadable key were sealed later.

The report holds no locations, tokens or keys. When you ask for help, paste it whole.

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
