# Life360 flow analysis (reference study for the redesign)

Issue: #28. **Method and limits, stated honestly:** the Life360 web pages were
not fetched or scraped, and no Life360 assets, copy, icons or screenshots are
used here. This is written from (a) widely documented public product behaviour
(app-store listings, help-centre-level knowledge, public reviews) as recalled,
and (b) Orbitly's own screens in `app/lib/screens`. Life360 behaviour can
have changed and is **unverified against the live product**. The issue's "15
Page Flows" list was not available in the issue text, so the 15 flows below are
the standard journeys of this product category; the maintainer should confirm
the intended list. Pages that need a paid Life360 account or an installed app
(Gold/Platinum tiers, Driver Report details, Crash Detection settings) are
marked **inaccessible - not observed**.

Legend for the Orbitly column: **Have** (screen exists), **Partial**, **Gap**.

| # | Flow | What Life360-style apps do (public behaviour) | Orbitly today | Status |
|---|---|---|---|---|
| 1 | Welcome / value pitch | Short carousel, then Create account or Log in | `welcome_screen.dart`, `onboarding_screen.dart` | Have |
| 2 | Sign up | Phone/email, name, password; permission education follows | `sign_up_screen.dart`, invite-gated registration | Have |
| 3 | Log in / reset | Email or phone login; reset by link/code | `login_screen.dart`, `reset_password_screen.dart`, `issue_reset_code_screen.dart` (operator-issued codes, no email) | Have (differs by design) |
| 4 | Permission onboarding | Staged location ("Always"), motion, notification, battery prompts with explanation | `permissions_screen.dart`, battery-optimization intent | Have |
| 5 | Create or join a Circle | Create with name; join by invite code or link; multiple circles | `create_or_join_circle_screen.dart`, `circle_create_screen.dart`, `join_circle_screen.dart`, `invite_screen.dart`, multi-circle (`docs/design/CIRCLES.md`) | Have |
| 6 | Main map | Full-screen map, member bubbles with battery/status, bottom sheet of members | `map_screen.dart`, `app_shell.dart`, `docs/bubbles.md` | Have |
| 7 | Member detail | Tap a member: address, last updated, battery, speed, history entry, check-in/ping | `member_detail_screen.dart`, `member_profile_screen.dart` | Have |
| 8 | Places / geofences | Add places with radius; arrival/departure alerts per member | `places_screen.dart`, `place_picker_screen.dart`, `add_locations_screen.dart`, `place_alert_rules_screen.dart` | Have |
| 9 | Location history | Day list, route with stops; paid tiers extend the window | `daily_history_screen.dart`, `day_detail_screen.dart`, `trips_screen.dart`, `trip_detail_screen.dart` | Have (no paywall) |
| 10 | Driving safety | Trip list, hard-braking/speeding/phone-use events, weekly score | `driving_tab_screen.dart`, `driving_report_screen.dart`, `family_driving_report_screen.dart`, `docs/driving.md` | Have (phone-use event: Gap) |
| 11 | Crash detection | Detects a crash, countdown, contacts emergency services/contacts | `crash_countdown_screen.dart`, `crash_reports_screen.dart` | Have (professional dispatch: not offered) |
| 12 | SOS / Help alert | One-tap alert to circle with location; paid tiers add dispatch | `sos_screen.dart`, `help_alert_screen.dart`, `alert_received_screen.dart`, `alert_status_screen.dart`, `safety_hub_screen.dart` | Have |
| 13 | Check-in and chat | "I'm here" check-in, circle messages | `check_in_screen.dart`, `chat_screen.dart`, `inbox_screen.dart`, `docs/chat.md` | Have |
| 14 | Settings, notifications, privacy | Per-circle location sharing toggle, notification prefs, delete account, ghost/pause | `settings_screen.dart`, `notification_prefs_screen.dart`, `security_screen.dart`, `two_factor_screen.dart`, `sessions_screen.dart`, `delete_account_screen.dart`, `privacy_policy_screen.dart` | Have |
| 15 | Membership / upsell | Free/Gold/Platinum tiers, paywall for history length, Tile devices, ID theft protection | - | Intentionally absent (self-hosted, no tiers) |

Inaccessible - not observed: tier-specific screens (extended history, roadside
assistance, ID-theft products, Tile hardware pairing), account-recovery edge
cases, and any flow gated by a US phone number.

## Takeaways for the redesign

- Map-first shell with a draggable member sheet is the organising pattern; Orbitly already follows it (`app_shell.dart`, `map_screen.dart`). Remaining polish is in density of the member sheet and tablet layout (`docs/ux/LARGE_SCREEN.md`).
- Onboarding sequences permission education *before* the OS prompt and stages "Always" location after While-in-Use; keep this order (`permissions_screen.dart`).
- Safety features are grouped in one hub; Orbitly's `safety_hub_screen.dart` matches. A visible "all clear" circle status is a possible addition.
- Gaps worth considering: phone-use-while-driving events, a pause/"ghost" mode surfaced next to the map (check against `docs/safety.md`), and a first-run checklist ("add a place", "invite someone").
- No paywall, ads or data-sale flows exist or should be added; this is a privacy differentiator (`PRIVACY.md`).

Do not copy Life360 trademarks, copy text, icons or imagery. Visual design stays
governed by `docs/ux/DESIGN_SYSTEM.md`.
