# OpenFamily app design system

Small, code-first. Everything lives in `app/lib/theme` and
`app/lib/widgets/ds`. Import `theme/app_theme.dart` (tokens are re-exported)
and `widgets/ds/ds.dart`.

## Identity

Light is **Ice**: lime on blue-grey paper. Dark is **Night**: brighter lime on
charcoal. Lime is the action colour (buttons, selected states, pins), never a
page wash. Colours come from `AppColors` and the `BrandTheme` extension
(`BrandTheme.of(context)`: `paper`, `sheet`, `accent`, `accentInk`,
`onAccent`). Use `accentInk` when lime is a glyph or label on paper (it is
AA-dark on Ice, bright on Night). Compat aliases (`AppColors.purple`, etc.)
remain so older screens compile; new code should not use them.

## Tokens (`theme/tokens.dart`)

| Group | Values |
|---|---|
| `AppSpace` | xxs 2, xs 4, sm 8, md 12, lg 16, xl 20, xxl 24, xxxl 32 |
| `AppRadius` | sm 8, md 12, lg 16, xl 24 (sheet top), pill |
| `AppType` | title 22/800, headline 17/700, body 15/600, secondary 13/500, label 12/700 caps |
| `AppMotion` | fast 150ms, normal 250ms; `AppMotion.of(context, d)` returns zero when the OS disables animations |
| `kMinTarget` | 48dp minimum interactive size |

Rules: no hard-coded spacing or radii in new code; no fixed-height boxes around
text (text scales to 200%); colour never carries meaning alone (every chip and
row has a text label); every tap target is at least 48dp; every icon-only
control has a tooltip/semantic label.

## Widgets (`widgets/ds`)

| Widget | Use |
|---|---|
| `DsPillButton` | Stadium button: `filled` (lime), `tonal`, `outlined`, `danger` (SOS). Optional icon. |
| `DsMapButton` | 48dp round floating control over the map (settings, layers, locate). Tooltip is its label. Optional attention badge. |
| `DsSectionHeader` | Small-caps group label, marked as a semantic header. |
| `DsListRow` | Avatar/icon, title, status line, trailing, optional chevron; `selected`, `destructive`; `DsListRow.iconTile` for settings icons. |
| `DsToggleRow` | Row with a `Switch`; the whole row toggles; exposes toggled semantics; `null` onChanged disables. |
| `DsSheetScaffold` / `DsDragHandle` | Rounded sheet surface with handle and optional title/header. |
| `DsSegmentedTabs` | Equal-width pill tabs (People / Places). |
| `DsStatusChip` | One glanceable fact ("Battery 18%"). |
| `DsEmptyState`, `DsErrorState`, `DsOfflineBanner` | Calm, illustration-free states with an optional action. `DsErrorState` takes an `icon` (cloud-off for offline). |
| `DsPage` | Form / onboarding page: app bar (+ step indicator), readable-width scrolling body, pinned actions. At text larger than 140% the actions scroll with the content. |
| `DsHeading` | Page title + calm supporting line (semantic header). |
| `DsMessage` | Inline error / success / info with icon AND words, live region. |
| `DsOptionCard` | Big tappable choice (create / join). One semantic button. |
| `DsBusyButton` | `DsPillButton` that swaps to "Please wait" while busy. |
| `DsSkeleton`, `DsSkeletonList` | Loading placeholders; static when the OS removes animations. |
| `OnboardingStepIndicator` | "Step X of Y" with segments, used as `DsPage(step:, totalSteps:)`. |

## App shell

`AppShell` (`screens/app_shell.dart`) hosts four lazily-built, state-keeping
tabs in an `IndexedStack` under a Material 3 `NavigationBar`:

1. **Location** - `MapScreen` rendering `LocationTabView`: full-bleed map,
   settings button, circle pill (switcher), invite button, Check in / SOS
   pills, layers and locate buttons, and a draggable People / Places sheet.
   The map widget is a black box passed to `LocationTabView`, so the tile
   layer can change without touching the layout.
2. **Driving** - who is driving now; each row opens `TripsScreen`.
3. **Safety** - SOS, check in, help alert, alert history, emergency contacts.
4. **Circle** - profile, circles, invite, places, security, settings.

Back on any tab other than Location returns to Location; back on Location
leaves the app. Routes pushed on the root navigator (alert screens, SOS) cover
the bar. `AppShell.requestTab(AppTab.safety)` switches tabs from non-widget
code (works before the shell mounts). There is deliberately no chat button;
`LocationTabView` has a marked slot top-right for it.

## Testing

* `test/widgets/ds_widgets_test.dart`, `location_tab_view_test.dart`,
  `test/screens/app_shell_test.dart` use `test/support/location_fixtures.dart`
  (fake members, circles, places, a drawn stand-in map).
* Golden renders: `OF_GOLDENS=1 flutter test --update-goldens
  test/goldens` writes `test/goldens/*.png` (Roboto loaded from the SDK).
  They are skipped unless `OF_GOLDENS=1`, so a normal `flutter test` does not
  compare pixels.

## Second wave (onboarding, auth, family, security)

Welcome (three value-prop pages), sign up, sign in (with the two-factor /
recovery-code step), reset password, create-or-join, create family, join,
invite, permissions (location Always, notifications, motion, Android battery
optimization), family, profile, circles, circle detail / create and the
security screens all use `DsPage`, themed inputs (`inputDecorationTheme`: filled
sheet colour, 12dp radius, `accentInk` focus ring) and the shared states.
`security_widgets.dart` keeps its names (`BusyButton`, `ErrorText`,
`LoadStateView`, `Callout`) but renders with the design system.

The invite screen leaves a keyed empty slot (`invite-qr-slot`) between the code
and the actions for the QR code / join link of issue #40.

Goldens for these screens live in `test/goldens/r2_*.png` (light, dark, and
200% text for welcome, sign in and permissions).
