# Bar Inventory — reference material for the OpenFamily admin panel

This file is the concrete "bar" (reference) for a gauntlet-loop build of a polished web
admin panel for **OpenFamily**, a self-hosted family location tracker. The two references
are a reference live web map (map view) and Vercel's dashboard (admin panel).

> **Method & limits.** Both reference apps are behind login walls, so no authenticated
> screenshots could be captured directly. Material below was gathered from *public* sources
> only, via direct fetches (the `web_search` tool returned no results in this session, so all
> sources were reached by known URL, not discovered by search). Image URLs were verified
> hotlinkable with HTTP HEAD where noted. **Nothing below is fabricated**: every hex/token is
> quoted from a fetched public page, and where a value could not be verified it is explicitly
> marked "NOT VERIFIED — not found in fetched source."

---

## 1. Reference map

### Source reality check
- The reference site is **Cloudflare-blocked** to automated fetch (HTTP 403). The live web map at
  the reference site is login-gated on top of that, so **no public screenshot of the actual web map
  was obtainable.**
- The closest public, verified-hotlinkable reference is the **App Store listing screenshots**
  (Apple iTunes Search API, app id `384830320`). These are the
  *mobile* app screens; the reference app's web map mirrors the same map styling, member bubbles, and
  status indicators as the mobile map. Treat these as the map-view reference, with the caveat
  that the web layout (side panel etc.) is not shown.
- No reference-app brand design-system page / public hex tokens were reachable. Brand hex values
  below are **NOT VERIFIED** and intentionally omitted rather than invented.

### Design inventory (inferred from App Store screens + app description)
- **Layout (mobile map):** Full-bleed map fills the screen; floating translucent cards/bars
  overlay the map (member strip / place cards). Member avatars shown as circular "bubbles"
  on the map at each member's current location. A bottom member list/strip with avatars +
  names. Map is the dominant surface (~70–80% of screen).
- **Member representation:** Circular avatar bubbles pinned to map positions; each member has
  a distinct color ring so multiple members are distinguishable at a glance.
- **Status indicators:** Driving vs. walking/stationary activity state; battery level shown per
  member; "last seen"/location timestamp; place-arrival status (arrived at Home/School/Work).
- **Circle/group concept:** "Circles" are the grouping unit (family circle); a circle switcher
  selects which group of members is visible. (Note: competitor "Family Nest" renamed Circles
  to "Nests" — confirms the Circle pattern is the industry norm for this category.)
- **Places:** Saved locations (Home, School, Work) drawn as pins with entry/exit alerts.
- **Color palette:** Primary brand color is a **teal/cyan** (visible in the app icon,
  `artworkUrl512`, a solid teal rounded-square). Exact hex **NOT VERIFIED**. UI chrome is
  light/white cards on the map. Member accent colors appear to be a small fixed palette
  (one distinct hue per member).
- **Typography:** System sans (mobile); no reference-app-specific typeface found. **NOT VERIFIED.**
- **Motion:** Live position updates (bubbles move on the map); no public motion spec found.
  **NOT VERIFIED.**
- **Features visible across the screenshot set:** Location sharing map, Place Alerts, Family
  Driving Summary, Individual Driver Reports, Crash Detection w/ dispatch, Pet GPS tracker,
  Bluetooth (Tile) tracker, Roadside Assistance.

### Best image URLs (all verified HTTP 200, `image/jpeg`, Apple CDN `is1-ssl.mzstatic.com`)
> The `WxHbb.jpg` suffix is a resize directive — you can request a larger render by changing
> the dimensions (e.g. `1242x2208bb.jpg` confirmed working for the map shot, ~689 KB).
> Source: iTunes Search API for app id `384830320`.

- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/d7/6d/b2/d76db21d-672a-6fe1-8c3c-dc3627e1449b/03_Location_Sharing.jpg/392x696bb.jpg` — **THE map view**: member bubbles on a full-screen map, the primary reference for the map view.
  - Higher-res: same path with `/1242x2208bb.jpg` (verified 200).
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/aa/8f/21/aa8f2155-1da5-cf5e-1361-1930e68ff963/05_PLACE_ALERTS.jpg/392x696bb.jpg` — Place Alerts: saved-place pins + arrival/leave alerts UI.
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/52/57/1a/52571ad9-16f7-fe56-3e84-7bd13533fef3/06_FAMILY_DRIVING_SUMMARY.jpg/392x696bb.jpg` — Family Driving Summary: per-member driving stats cards.
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/15/bd/7f/15bd7f00-cd79-b2a5-9169-cb47097a0206/07_INDIVIDUAL_DRIVER_REPORTS.jpg/392x696bb.jpg` — Individual Driver Reports: detail view of one member's trip/behavior.
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/f8/38/5f/f8385f6f-7b49-f0fb-5e15-b96d97fd8f75/08_CRASH_DETECTION_WITH_DISPATCH.jpg/392x696bb.jpg` — Crash Detection + emergency dispatch screen.
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/fa/f5/f8/faf5f861-48ed-26de-ac52-edcc959706a5/04_PET_GPS_TRACKER.jpg/392x696bb.jpg` — Pet GPS tracker on the map (shows non-person entities as bubbles).
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/9e/db/ec/9edbec97-4634-99b7-7f05-7d89f7030983/09_BLUETOOTH_TRACKER.jpg/392x696bb.jpg` — Bluetooth (Tile) item tracker integration.
- `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/1d/c4/e2/1dc4e25d-571f-4fe1-11cc-446c716f8179/10_ROADSIDE_ASSISTANCE.jpg/392x696bb.jpg` — Roadside Assistance screen.
- App icon (teal brand mark): `https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/e1/c1/63/e1c1638d-8697-c1f4-7e0b-c5cd424b3871/AppIcon-0-0-1x_U007ephone-0-1-0-0-85-220.png/512x512bb.png`

### What makes the reference map feel polished (critic checklist)
1. **Map-first layout** — the map dominates; chrome is translucent overlay cards, not a separate
   pane stealing map real estate.
2. **Member bubbles with distinct per-member color rings** — multiple members are instantly
   distinguishable; color is the primary identity device.
3. **Rich status per member** — activity (driving/walking/stationary), battery %, and
   last-seen time are surfaced on the member, not buried.
4. **Places as first-class pins** with arrival/leave alerts — Home/School/Work are visible
   on the map and trigger notifications.
5. **Circle/group switcher** — switching which group of members you're viewing is one tap.
6. **Calm, light chrome** — white/translucent cards over the map; the teal brand accent is
   used sparingly for primary actions/branding.
7. **Live, moving bubbles** — positions update in place; the map feels alive, not a static
   snapshot.

### Gaps (explicit)
- **No verified reference-app brand hex values.** (the reference site blocked; no public brand/press kit
  reached.) Do not invent the teal hex — confirm against the app icon or a fetched brand
  asset before using.
- **No public web-map screenshot.** The reference images are mobile app screens. The web map's
  side-panel layout is unknown from public sources; infer the member list as a side panel for
  the desktop build but flag it as inferred.
- **No reference-app typeface / spacing scale** found publicly.

---

## 2. Vercel — dashboard (admin panel)

### Source reality check
- The live dashboard at vercel.com/dashboard **redirects to /login** (auth-gated); no
  authenticated screenshot could be captured.
- However, Vercel publishes its **entire design system ("Geist") publicly** at
  `vercel.com/geist/*` — this is the actual system the dashboard is built from, including the
  color role system, full typography scale, material/elevation presets, and a component
  catalog that mirrors the dashboard's UI (Avatar, Badge, Button, Empty State, Skeleton,
  Loading Dots, Status Dot, Context Card, Tabs, Table, Command Menu, etc.). This is
  **stronger than a screenshot** for a builder and is the primary Vercel reference below.
- Individual dashboard docs pages (`/docs/projects`, `/docs/getting-started-with-vercel`)
  were fetchable but their bodies are dominated by repeated site nav and were truncated before
  the embedded screenshot images; **specific full-page dashboard screenshot URLs could not be
  extracted from the docs HTML via text fetch.** The Geist component examples *do* contain
  dashboard-style mockups (e.g. a `/dashboard/overview` path card with Hobby/Pro/Enterprise
  badges shown on the Colors page).

### Design inventory (from the public Geist design system)
- **Foundations:** Colors, Typography, Materials (elevation) — published at
  `vercel.com/geist/colors`, `/geist/typography`, `/geist/materials`.
- **Color system (roles, not single hexes):** Two backgrounds (Background 1 default,
  Background 2 secondary). Ten numbered color roles used consistently across components:
  - Colors 1–3 = component backgrounds (default / hover / active)
  - Colors 4–6 = borders (default / hover / active)
  - Colors 7–8 = high-contrast backgrounds (e.g. upgrade prompts)
  - Colors 9–10 = text & icons (Color 9 secondary, Color 10 primary)
  - 10 scales total: Gray, Gray-alpha, Blue, Red, Amber, Green, Teal, Purple, Pink. P3 color
    used where supported.
  - **Note:** raw hex values are rendered as visual swatches on the page, not as text, so
    they were **NOT extractable** from the fetched HTML. The *structure* (the 1–10 role ladder
    + two backgrounds + named scales) is verified; the literal hexes are not. Don't invent
    them — pull them from the Geist Figma/Tailwind source or by sampling the live swatches.
- **Typography (verified scale):** Geist Sans for text, Geist Mono for code/mono labels.
  Classes pre-set font-size + line-height + letter-spacing + weight. Named styles actually
  used in the dashboard:
  - Headings: `text-heading-72 / 64 / 56 / 48 / 40 / 32 / 24 / 20 / 16 / 14`
  - Buttons: `text-button-16` (largest), `text-button-14` (default), `text-button-12` (tiny, in inputs)
  - Labels (single-line, generous line-height, pairs with icons): `text-label-20/18/16/14/13/12`,
    plus mono variants `text-label-14-mono / 13-mono / 12-mono`; `text-label-13` is **tabular** for numbers.
  - Copy (multi-line, higher line-height): `text-copy-24/20/18/16/14/13`, `text-copy-13-mono` for inline code.
  - Modifiers: `<strong>` inside a class gives **Strong**; some labels use **CAPS** (label-12).
- **Materials / elevation (verified radii + shadow roles):** Material encodes elevation role;
  pick by where the element sits in the layered hierarchy.
  - Surface: `material-base` (everyday, radius 6px), `material-small` (slightly raised, 6px),
    `material-medium` (12px), `material-large` (12px).
  - Floating: `material-tooltip` (lightest shadow, corner 6px, only floating element with a stem),
    `material-menu` (lift, radius 12px), `material-modal` (further lift, 12px),
    `material-fullscreen` (biggest lift, radius 16px).
  - Rule: don't stack two materials on the same element; align elevation with z-index band; use
    the lowest elevation that still reads as raised; pair shadow with focus-visible ring.
- **Components catalog (verified present, each at `vercel.com/geist/<name>`):** Avatar, Badge
  (incl. Pill), Banner, Breadcrumbs, Browser, Button, Calendar, Checkbox, Choicebox, Clearable
  Input, Code Block, Collapse, Combobox, **Command Menu**, Context Card, Context Menu, Copy
  Button, Description, Destructive Action Modal, Dots Menu, Drawer, **Empty State**, Entity,
  Error, Error Card, Feedback, Fieldset, File Tree, Gauge, Grid, Input, JSON View, Keyboard
  Input, Label, **Load More Button**, **Loading Dots**, Menu, MiddleTruncate, Modal,
  Multi Select, Note, Pagination, Phone, Progress, **Project Banner**, Radio, Relative Time
  Card, Scroller, Search Input, Select, Separator, Sheet, Show more, **Skeleton**, Slider,
  Snippet, **Spinner**, Split Button, **Status Dot**, Switch, **Table**, Tabs, Text With Copy
  Button, Textarea, Theme Switcher, Toast, Toggle, Tooltip, Video.
  - The admin-panel-relevant subset to study: Sidebar (file-tree/nav pattern via File Tree +
  Tabs + Menu), top bar (Search Input + Command Menu + Avatar + Theme Switcher), project
  list (Context Card / Entity / Table + Status Dot), empty/loading states (**Empty State**,
  **Skeleton**, **Loading Dots**, **Spinner**), badges (**Badge** / Pill for Hobby/Pro/Enterprise
  plan tags), buttons (**Button** + Split Button + Dots Menu), feedback (Toast + Note + Feedback).
- **Aesthetic notes from the Geist intro:** "high contrast, accessible color system"; the
  **Grid** is described as "a huge part of the new Vercel aesthetic" — study `vercel.com/geist/grid`.
  Typeface "specifically designed for developers and designers" (`vercel.com/font`).
- **Overall feel:** Black/white/gray monochrome base with a single restrained accent; very
  high contrast; tight, consistent spacing driven by the type+material system; near-monochrome
  dark dashboard with crisp 6/12/16px radii and layered, restrained shadows; developer-grade
  mono labels and tabular numerals for data.

### Best reference URLs
**Primary (the design system itself — these are the bar):**
- `https://vercel.com/geist/introduction` — Geist overview; links to foundations + brands + components.
- `https://vercel.com/geist/colors` — color role system (Backgrounds 1–2, Colors 1–10, 10 scales); includes a dashboard-style `/dashboard/overview` mockup card with Hobby/Pro/Enterprise badges.
- `https://vercel.com/geist/typography` — the full verified type scale (headings/buttons/labels/copy + mono variants, tabular numerals).
- `https://vercel.com/geist/materials` — elevation presets with verified radii (6/12/16px) and shadow roles.
- `https://vercel.com/geist/grid` — the grid system Vercel calls central to its aesthetic.
- `https://vercel.com/font` — Geist Sans / Geist Mono typefaces.
- `https://vercel.com/geist/brands` — Vercel/Next/Turbo/v0/eve logo & brand assets (also "Download Brand Assets / Brand Guidelines" in the site header).
- Component pages (admin-panel-relevant): `https://vercel.com/geist/avatar`,
  `/geist/badge`, `/geist/button`, `/geist/empty-state`, `/geist/skeleton`,
  `/geist/loading-dots`, `/geist/spinner`, `/geist/status-dot`, `/geist/context-card`,
  `/geist/entity`, `/geist/table`, `/geist/tabs`, `/geist/command-menu`,
  `/geist/search-input`, `/geist/file-tree`, `/geist/menu`, `/geist/dots-menu`,
  `/geist/toast`, `/geist/note`, `/geist/project-banner`, `/geist/theme-switcher`.
- Changelog (public, often shows dashboard UI in posts): `https://vercel.com/changelog`
- Docs (public, embed dashboard screenshots in body — fetchable but nav-heavy): `https://vercel.com/docs/projects`, `https://vercel.com/docs/getting-started-with-vercel`, `https://vercel.com/docs/deployments`.

**Dashboard screenshot image URLs:** **NOT EXTRACTED** — the docs HTML embeds dashboard
images, but text fetches truncated on the repeated site nav before reaching the body image
tags. A logged-in screenshot of the real dashboard was not obtainable from public sources in
this session. Use the Geist component examples (which render dashboard-style mockups) as the
visual reference, and supplement by manually viewing the changelog/docs in a browser.

### What makes Vercel feel polished (critic checklist)
1. **Monochrome, high-contrast base** — black/white/gray with a single restrained accent;
   no rainbow status colors except the named semantic scales (Red/Amber/Green/Blue used
   sparingly for state).
2. **Disciplined color *role* ladder** — every surface uses Background 1/2 and Color 1–10 by
   role (default/hover/active for both bg and border), so hover/active states are consistent
   everywhere. Check the build for this consistency, not ad-hoc colors.
3. **Geist Sans + Geist Mono, used by role** — mono for code, IDs, and number pairs; tabular
   numerals (`text-label-13`) for any aligned numeric columns. Sans for everything else.
4. **Type scale, not freeform sizes** — only the named heading/button/label/copy classes; a
   harsh critic should flag any off-scale font size.
5. **Elevation by Material, not hand-rolled shadows** — radii locked to 6/12/16px and shadow
   keyed to role (base→small→medium→large→tooltip→menu→modal→fullscreen). Over-elevation is a
   common fail; the dashboard should use the *lowest* elevation that reads as raised.
6. **Real empty + loading states** — dedicated Empty State, Skeleton, Loading Dots, and
   Spinner components; never a blank panel or a generic browser spinner.
7. **Status Dot + Badge for state** — small colored dots for live status, Pill/Badge for plan
   tags (Hobby/Pro/Enterprise) and deployment states (Ready/Building/Error).
8. **Crisp admin density** — Context Cards / Entity rows / Tables with MiddleTruncate for long
   IDs, Relative Time Cards for timestamps, Copy Button next to any value a dev would copy;
   Command Menu (⌘K) and a Search Input in the top bar.

### Gaps (explicit)
- **Raw Geist hex values NOT extracted** (swatches are visual, not text in the HTML). The
  color *structure* is verified; the literal hexes are not. Obtain them from the Geist Figma
  file or by sampling the live `vercel.com/geist/colors` swatches in a browser — do not invent.
- **No full-page authenticated dashboard screenshot** captured from public sources in this
  session. The visual reference is the Geist component mockups + the changelog/docs (to be
  viewed manually).