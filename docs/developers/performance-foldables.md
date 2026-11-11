# Performance on foldables and large, high-refresh screens

Rendering and layout work for the Galaxy Z Fold class of phones: what changed, what the tests lock, and how to measure on a real device.

**Nothing here was measured on a phone.** There was no phone available. The changes come from reading the code and from Flutter widget tests (build and
layer counts in the Flutter test VM). They prove structure (what is rebuilt, what is recreated, what is on screen),
not frame times. The section "Measuring on a real Z Fold" lists what to run; it has not been run.

## What changed

1. **Fold and unfold no longer recreate the map or the tabs.** Both layout switches used to put the same widget in a
   different place in the tree, so Flutter threw the old one away and built a new one:
   - `AppShell` swapped the bottom bar layout for the rail layout (width >= 840 dp, or landscape >= 560 dp). The
     banners plus the four tabs were rebuilt, which restarted the map screen: camera reset, WebSocket reconnected,
     location reporter recreated.
   - `LocationTabView` swapped the bottom sheet layout for the two-pane layout (body width >= 720 dp, or clearly wide).
     The `FlutterMap` was recreated and re-fitted.

   Both now hold a `GlobalKey` (`KeyedSubtree`), which lets Flutter move the existing element to its new parent. The
   regression test (`test/perf/fold_resize_test.dart`) failed before the change (tab state created twice) and passes
   after.
2. **One layout rule.** `MapScreen` used the window size to decide whether a sheet covers the lower map; the layout
   used the body size (window minus the rail). It now asks `LocationTabView.isTwoPaneSize` with the body's own size,
   so "centre the camera above the sheet" is only applied when there really is a sheet.
3. **Narrower `MediaQuery` subscriptions.** The two remaining `MediaQuery.of(context)` calls (chat bubble width,
   the add-server sheet) now use `sizeOf` / `viewInsetsOf`, so they no longer rebuild on unrelated changes.
4. **Manifest.** `MainActivity` already handled `orientation|screenSize|smallestScreenSize|screenLayout|density|...`
   itself, so a fold does not restart the activity or the Flutter engine. Added `android:resizeableActivity="true"`
   explicitly. There is no portrait lock, no `maxAspectRatio`, and nothing that disables Impeller or forces software
   rendering (checked in the manifest, Gradle files and Dart: no `EnableImpeller` or software-rendering flags). The
   test `test/perf/android_manifest_foldable_test.dart` locks this.

Already in place before this work (and kept): the rail and two-pane layouts, `MediaQuery.sizeOf` in hot paths,
the single motion `Ticker` for markers that stops when the tab is hidden, the saveLayer allow-list test, `reduceEffects`
on low-tier devices, and the roster/marker repaint isolation (`test/perf/*`).

## Layout rules

| Width | Result |
| --- | --- |
| window < 560 dp, or portrait < 840 dp | Bottom navigation bar, map plus draggable sheet |
| window >= 840 dp, or landscape >= 560 dp | Navigation rail on the leading edge |
| tab body >= 720 dp, or wider than 1.2 x its height and >= 560 dp | Map beside a fixed People / Places panel |

Tested sizes (dp): 412x915 cover, 884x1104 inner portrait, 1104x884 inner landscape, 442x1104 and 884x552 split
windows, each at text scale 1.0 and 1.3. No overflow at any of them.

## What was reviewed and left alone

- Shadows: the sheet, floating buttons and avatar markers use `BoxShadow`; avatar shadows are dropped on low-tier
  devices. Clips are `hardEdge`/default (no `antiAliasWithSaveLayer`). `Opacity` is used in four places for disabled
  states only. The test `save_layer_audit_test.dart` fails if a new offscreen-layer widget appears.
- Marker motion: a single `Ticker` drives a motion hub; the marker layer updates through a `ValueNotifier`, not
  `setState` on the screen. Verified by `live_motion_test.dart` and `marker_layer_test.dart`.
- Images: avatars are decoded at display size; chat images use `cacheWidth`.
- Startup: `main()` reads settings in parallel and does not await plugins before `runApp`.
- Page transitions use Flutter's `FadeForwards` builder. It is a framework class; no jank can be proven or
  disproven without a device.

## Measuring on a real Z Fold

Build a profile build (release-like, with tooling): `flutter run --profile` (add `--trace-skia` to include raster
events in the timeline; under Impeller use the DevTools Performance tab instead).

Frame statistics (run after 30 s of use, reset first):

```
adb shell dumpsys gfxinfo app.openfamily reset
# ...pan the map, drag the sheet, switch tabs...
adb shell dumpsys gfxinfo app.openfamily framestats
```

Look at "Janky frames" and the 90th / 95th / 99th percentile frame times. At 120 Hz the budget is 8.3 ms per frame.


Emulate fold sizes on any phone or emulator:

```
adb shell wm size 1812x2176      # inner screen portrait
adb shell wm density 373
adb shell wm size reset && adb shell wm density reset
```

The Android Studio "Resizable" and "7.6 Fold-in" emulators switch posture live; use them to fold and unfold while the map
is open and check that the camera stays put. In One UI, also try the pop-up view and split-screen with the divider
dragged.

Perfetto: `adb shell perfetto -o /data/misc/perfetto-traces/t -t 20s sched freq gfx view` then open it at
ui.perfetto.dev and look at the app's `Choreographer#doFrame` slices. DevTools Performance (profile mode) shows
build, layout and paint per frame; check that panning the map only repaints the marker layer.

What to look at first: dragging the People sheet on the inner screen, pinch-zooming with 10+ members, switching tabs,
and fold/unfold with the map open (expect no flash of loading state and no reconnect).
