# Large screens and Android system UI

The app draws edge to edge (`SystemChrome` edgeToEdge in `main.dart`,
`WindowCompat.setDecorFitsSystemWindows(false)` in `MainActivity`; Android 15+
enforces it anyway). Every screen must therefore pad itself from
`MediaQuery` insets, never from an assumed status-bar height.

## Rules

- System bars are transparent; icon brightness follows the app theme
  (`systemOverlayFor` in `theme/app_theme.dart`), applied in
  `MaterialApp.builder` and in `AppBarTheme`.
- App bars handle the status bar. Bodies use `Scaffold` + `DsBody` (safe left,
  right, bottom; centered at `kContentMaxWidth` = 640 dp) or `DsPage` (560 dp).
- The bottom `NavigationBar` already insets for the gesture bar. Full-screen
  map overlays add `MediaQuery.paddingOf(context).bottom` themselves.
- Pinned actions go outside the scroll view so the keyboard (`viewInsets`)
  never hides them (place picker, `DsPage`).
- Cutout: `windowLayoutInDisplayCutoutMode=shortEdges` (values-v28 and up).
- Predictive back: `android:enableOnBackInvokedCallback="true"`; back handling
  is `PopScope` (AppShell returns to Location first).

## Breakpoints

| Width / orientation | Layout |
| --- | --- |
| <= 412 dp portrait | unchanged phone layout |
| 480 dp (S26 Ultra class) | phone layout, compact 2x2 driving tiles |
| >= 520 dp content | four driving tiles across |
| >= 840 dp, or landscape >= 560 dp | `NavigationRail` instead of bottom bar; Location is map + side panel (no sheet); place picker is map + form |
| content cap | 560 (forms), 640 (lists/settings), 760 (detail with maps) |

## Verifying

`test/support/golden_utils.dart` applies a `DeviceSpec` (size, status bar,
cutout, gesture bar, keyboard, text scale) to the test view and paints fake
system chrome. `test/widgets/insets_test.dart` asserts the inset rules.
Goldens: `OF_GOLDENS=1 flutter test --update-goldens test/goldens/ls_golden_test.dart`
(files `test/goldens/ls_*`). Not covered: real device behaviour.
