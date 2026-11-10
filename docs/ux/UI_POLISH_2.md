# UI polish 2

Owner feedback (Galaxy S26 Ultra, dark, 1.0 text, about 412 dp): "that UI just looks ugly". Earlier
feedback still stands: too much text, too squished, must work on a Z Fold 4 cover display (about
344 dp), must feel fast. This pass changes layout, hierarchy, spacing and copy length only. No
behaviour, key or logic changes. Code: `app/lib/widgets/ds`. Renders: `app/test/goldens/p2/`
(`polish2_golden_test.dart`).

## What is wrong today (from the five screenshots)

1. **Trips list.** Four stats wrap 3 + 1, so the average sits alone on a second line and every card is
   tall. The "Driving report" pill is pinned directly under the tabs with no gap, so scrolled cards
   slide under it and look overlapped. The "Processed by server" chip hugs the screen edge (0 dp)
   while everything else starts at 16.
2. **Circle processing setting.** Two left edges (the switch row is at 40 dp, headers and cards at 20).
   Heavy radio cards: a tinted selected card, an icon tile that only holds a radio mark, and up to seven
   lines of body text per option. A six-line paragraph and a bordered note close the page. Section
   headers are whole questions in capitals.
3. **Link another phone** (0.26.29 redesign, re-rendered at 390 and 344 / 1.5x): one left edge, one
   heading, numbered steps, one primary button, details folded away. It is fine; leave it. Only check
   that it keeps passing the narrow-layout test.
4. **Security.** One row carries a nine-line paragraph and a switch, so row heights range from 56 to
   about 220 dp. "Issue a reset code" and "Encryption keys" use the same key glyph, and the password glyph
   is visibly smaller than the others. Rows are flat on the page background with full-width rules, so
   nothing is grouped.
5. **Map and circle sheet.** The sheet header centres a sharing chip and an "Open circle details"
   button under a left-aligned title. "Location sharing: on" appears three times (pill, chip, and again
   in the row). "Private + server" appears on the map header AND in the row. The row's second line is a
   run-on of four facts joined by hyphens that wraps to two lines.

## Principles

* **One left edge.** Page gutter 16 dp (12 dp under 360 dp or at text over 130%). Cards, tabs, chip
  rows, stat strips and notes sit on the gutter. Inside a card, rows are inset 16 dp (12 narrow).
  Section headers and footnotes use the same inset, so header text, icon tiles and row titles start on
  one x. `DsSettingsList` and `DsRowGroup` do this for you through `DsRowScope`.
* **Type scale, three levels per screen.** Page title (app bar). Row title: `AppType.body` 15/600.
  Secondary: `AppType.secondary` 13/500, muted. `AppType.headline` 17/700 only for day headings and
  stat values. Section label: `AppType.label` caps, muted.
* **Icon tile.** One size (40 dp, radius 12, glyph 22, 14% tint) in every row of a group, and in a
  settings group the tiles are `decorative: true` so a narrow screen drops them from every row
  alike. Never two identical glyphs in one list. Red tile only for destructive rows.
* **Row rhythm.** Minimum 56 dp. Title one line at 390 dp / 1.0x. Second line one line at 390 dp / 1.0x
  (about 38 characters), never more than two at any size. A longer explanation goes behind the row's
  (i) (`info:`), not into the row.
* **Facts on a second line** are joined with `dsMeta([...])` ("2 people · Admin"): at most three
  parts, short words, no repeated facts.
* **Chips** go in a `DsChipRow`: left-aligned, 8 dp apart, wrapping. Never a lone chip off the gutter,
  never a chip that repeats what a control next to it already says.
* **Stats** go in a `DsStatStrip`: equal columns, value over label, one left edge. 4 items share one
  row when each column is at least 72 dp (scaled with text), else 2 + 2. 3 items go in one row or,
  when they cannot, a label-left / value-right list. Never 3 + 1, never a lone item.
* **Groups.** Quiet section label (1 to 3 words, no question mark, optional one-line caption), then
  a `DsRowGroup` card. Footnotes are `DsFootnote`, two lines at most.
* **Sheets.** Everything left-aligned under the handle (the scaffold now stretches its header).
  Actions are normal rows with a tile and a chevron, not centred buttons.
* **Pick-one options** are `DsRadioRow`s in a `DsRowGroup`: radio mark, name, one short line, (i).
  No tinted card, no icon tile around the mark. Selected is the filled mark plus "checked" semantics.
* **Honest copy.** Shorter, never softer. Where a long text moves behind an (i) it keeps its facts:
  required server processing is enforced (members cannot turn it off; a phone that has not switched
  over cannot send positions until it has), the server can read data of members who allow it, and the
  existing catch-up wording and its time window stay exactly as in the code. Do not add claims about
  delivery that the code does not make. Speeds are GPS estimates (the note stays).

## Changes per screen

### Trips (`trips_screen.dart`, `trip_widgets.dart`)

* Pinned header is only the 7 / 30 day tabs. Everything else scrolls in the list, so nothing
  can slide under a pinned control.
* First list children, on the gutter: `DsChipRow([LaneChip])` when the lane is known, 8 dp gap, then
  "Driving report" as a one-row `DsRowGroup` (tile `insights_rounded`, chevron, same key and
  semantics label "Report"). Remove the floating tonal pill. Phone-only variant gets the same chip row.
* `TripCard`: radius 16 (`AppRadius.lg`), padding 16. Row 1: `TripModeBadge`, 8 dp, the time range
  (body) filling the rest, chevron. Row 2: `DsStatStrip` with Distance, Duration, Top speed,
  Average. Semantic labels stay "Max GPS speed: ..." and "Avg GPS speed: ..." through
  `DsStat.semanticLabel`. `GpsSpeedNote` stays at the end of the list. Cards are about 40% shorter.
* Day headings: `AppType.headline`, on the gutter (drop the extra 4 dp).
* Tests that look for 'Max GPS speed' / 'Avg GPS speed' text (`trips_screens_test.dart` lines
  about 158 and 212) change to 'Top speed' / 'Average' (visible labels) or to the semantic labels.

### Circle processing setting (`processing_policy_screen.dart`)

* Body is a `DsSettingsList`. Keys unchanged (`policy-assist-switch`, `opt-allowed`,
  `opt-required`, `default-server`, `default-phone`, `policy-blocked`, `policy-setup-server`,
  `policy-readonly`).
* Switch row (in its own `DsRowGroup`): title "Server assistance", subtitle "On" or "Off", `info:` =
  today's long sentence plus `ProcessingCopy.operatorCanRead`. Blocked text and the set-up button follow
  the group as a `DsFootnote` (red) and a left-aligned tonal button, same gutter.
* Header "Members' choice", caption "Can members keep data on their phone?". Options as
  `DsRadioRow`: "Members may opt out" ("Default. Their choice in Settings."), "Server processing
  required" ("Members cannot turn it off."). Each `info:` is today's full text.
* Header "Default for members". "Server processing" ("Recommended. Phones switch it on and show a
  notice."), "Phone only" ("Members are asked."). `info:` = today's text for each.
* The six-line paragraph becomes a "How this works" row (tile `info_outline`, chevron) that opens
  `showInfoSheet` with the same text. The closing note becomes one `DsFootnote(icon:
  Icons.info_outline)`: "Every change is a signed entry in the key log that all members can see."
  (`operatorCanRead` is in the switch row's (i) and in the sheet.)
* Read-only note for non-admins: `ProcessingNote` stays, on the gutter.

### Security (`security_screen.dart`)

* `DsSettingsList`; three `DsRowGroup`s with quiet headers, tiles all `decorative: true`:
  "Sign in": Two-factor authentication ("On" / "Off"), Active sessions ("Where you are signed in"),
  Change password ("Signs out your other devices"), Issue a reset code (admins; "For a member who
  forgot theirs"). "Encryption": Encryption keys ("Device key, safety numbers, recovery phrase"), the
  key-backup `DsToggleRow` (title "Keep this phone's key through reinstalls", subtitle "On" / "Off" or
  the short problem line in the error colour, `info:` the existing platform text). "Your data":
  Download my data ("A JSON file of your data"; busy: "Preparing your file..."). Then a separate group
  with Delete account (red tile, "Permanently erase your account and data").
* Distinct glyphs: sessions `devices_outlined`, password `lock_outline`, reset code `lock_reset`,
  keys `vpn_key_outlined`, backup `restore`, download `download_outlined`, delete `delete_forever`.
* All row heights 56 to 72 dp at 390 / 1.0x.

### Circle sheet and map header (`location_tab_view.dart`)

* Sheet header (centred chip + button) is gone. "Location sharing: on / paused" is already on the circle
  pill and the paused banner. "Open circle details" becomes a normal row (tile `info_outline`, chevron)
  after the circle rows, shown for the selected circle only; same text, same behaviour.
* Circle row second line: `dsMeta(['2 people', 'Admin', 'Sharing paused'])`; only present facts. No
  "Shown on the map" text: the trailing check says it (give the check `semanticLabel: 'Shown on the
  map'`). No privacy words in the row: the map header badge is the one place for "Private + server",
  and the details screen has the rest.
* Map header keeps the single `PrivateCircleBadge` under the pill, centred over the map. Rows, tests
  that expect it twice (`private_circle_widgets_test.dart` line 50) are adjusted deliberately.
* Tests to update on purpose: `location_tab_view_test.dart` (the "Shown on the map" line, the sheet header
  chip) and anything that taps 'Open circle details' in the header.

### Link another phone

No change. Still render `p2/link_*` and keep `narrow_layout_test.dart` green.

## Shared widgets (this commit)

| Widget | Signature | Use |
|---|---|---|
| `DsSettingsList` | `({required List<Widget> children, Key? listKey, ScrollController? controller})` | Body of a settings page: readable width, gutter 16/12, bottom space; provides `DsRowScope`. |
| `DsRowGroup` | `({required List<Widget> children})` | Rounded card of rows; rows and dividers use the inset (16/12). |
| `DsRowScope` | `.maybeOf(context)`, `.insetFor(context)` | The shared inset. |
| `DsSectionHeader` | `(String title, {Widget? trailing, String? caption, EdgeInsetsGeometry? padding})` | Quiet caps label, aligned to the rows inside a `DsSettingsList`. |
| `DsFootnote` | `(String text, {EdgeInsetsGeometry? padding, IconData? icon})` | Two-line note under a group. |
| `DsRadioRow` | `({required String title, required bool selected, required VoidCallback? onTap, String? subtitle, String? info, String? infoTitle})` | One option of a pick-one group. |
| `DsListRow` | new `checked` (bool?) for exclusive-group semantics | Existing params unchanged. |
| `DsStat`, `DsStatStrip` | `DsStat({value, label, semanticLabel})`; `DsStatStrip({required List<DsStat> stats, double minColumnWidth = 72})` | Equal-column figures; regroups 2 + 2 or a label / value list; never 3 + 1. |
| `DsChipRow` | `({required List<Widget> children, WrapAlignment alignment})` | Start-aligned, 8 dp spaced chips. |
| `dsMeta` | `String dsMeta(Iterable<String?> parts)` | "a · b · c" second lines. |
| `DsSheetScaffold` | unchanged API; header and body now stretch left | Sheets. |

`DsToggleRow` and `DsListRow` read the group inset; outside a group or list they keep the old 20 dp
gutter, so untouched screens only change where they already used `DsRowGroup` (inset 20 to 16).

## How it is checked

`OF_GOLDENS=1 flutter test --update-goldens test/goldens/polish2_golden_test.dart` renders each
screen at 390 and 344 / 1.5x, dark and light, and fails on any overflow. Widget tests:
`test/widgets/ds_polish2_test.dart`. Not verifiable here: real device fonts (renders use Roboto),
real Samsung font scaling, motion and scrolling feel, TalkBack.

## Review round (critic findings, fixed)

* **Link another phone** now sits on the same 16 dp gutter as the lists (`DsPage.gutter`), and its step
  heading uses the 17 dp headline (`DsHeading(compact: true)`) instead of the 26 dp onboarding size.
* **Trips.** The 7 / 30 day track has a hairline so its edge is visible on the gutter; 16 dp under the tabs and
  12 dp between the lane chip and the report row. `DsStatStrip` shrinks every value of a strip together
  (never one cell). Driving cards are flat (sheet colour, no shadow, no border), the same surface as a row
  group; the light-theme shadow left a grey crescent at the bottom corners. Empty copy: "Trips show up after a
  few minutes of movement with sharing on."
* **Processing rules** (was "Circle processing setting"): "Server help" row, (i) only where a row hides a
  consequence (the switch, "Server processing required", "Phone only"); the visible footnote says the server
  can read data of members who allow it. A row with an (i) uses 8 dp vertical padding so it is as tall as a row
  without one (the 48 dp button sets the height).
* **Server processing (member / admin).** One signal per member row (chip or second line, not both); members
  who chose the phone are listed once (Members), the "not yet" list keeps only members someone can still act on.
  The reminder message is a row that copies it, with the text behind its (i). The status card uses the normal
  card surface. "Positions may not arrive until then." and "Some phones have not switched over yet." replace two
  flat claims (a catch-up window after a server key change means a position can still be relayed).
* **Security.** Download my data has a chevron (it is an action) and a one-line second line.
* **Circles sheet** uses the 16 dp inset; the details row is named after its circle ("Details for Foley Family").
