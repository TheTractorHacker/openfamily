# Store assets pipeline

How to produce the screenshots, feature graphic and icons for Google Play and the App Store, what is generated and what must be captured on a real device.

## What `scripts/store-assets.sh` does

```
scripts/store-assets.sh                  # needs only Docker
scripts/store-assets.sh --compose-only   # re-run just the layout step
```

1. Runs `app/test/goldens/store_screenshots_test.dart` in the Flutter image. It draws
   seven real app screens (people, places, chat, SOS, check-in, circles, private circle) at the pixel size of every store slot, using the same fictional fixtures
   as the user documentation screenshots: the **"The Rivera Family"** circle with Maria, Carlos,
   Sofia and Mateo (`app/test/goldens/docs_screenshots_test.dart`). If the demo-server work
   later publishes a different seed (`docs/release/DEMO_SERVER.md`), update the fixtures in that file
   so the store images match what a reviewer sees after signing in to the demo account.
2. `scripts/store-assets/compose.py` (Pillow) puts each render on the brand background
   with a caption and writes the exact final pixel sizes. It also makes the 1024 x 500
   feature graphic, the 512 px Play icon and the 1024 px App Store icon from `assets/brand`.
3. Output goes to `dist/store-assets/` (git-ignored) with a generated `README.md` that
   says what to upload where.

| Output | Pixels | Slot |
|---|---|---|
| `google-play/phone/` | 1080 x 1920 | Phone screenshots |
| `google-play/tablet-7in/` | 1200 x 1920 | 7-inch tablet |
| `google-play/tablet-10in/` | 1600 x 2560 | 10-inch tablet |
| `google-play/foldable-inner-screen/` | 1840 x 2208 | Large screens / foldable inner display |
| `google-play/feature-graphic-1024x500.png` | 1024 x 500 | Feature graphic |
| `google-play/icon-512.png` | 512 x 512 | Play icon |
| `app-store/iphone-6.9in-1320x2868/` | 1320 x 2868 | iPhone 6.9" |
| `app-store/iphone-6.5in-1284x2778/` | 1284 x 2778 | iPhone 6.5" |
| `app-store/ipad-13in-2064x2752/` | 2064 x 2752 | iPad 13" (only if offered on iPad) |
| `app-store/app-icon-1024.png` | 1024 x 1024 | Reference for the Xcode asset catalog |

Play screenshot limits (**verify**): PNG or JPEG, up to 8 MB, 2 to 8 images per slot, each
side between 320 and 3840 px, the long side at most twice the short side. Apple: PNG or JPEG
without transparency; composed images are saved as RGB.

## These are renders, not captures

The images are drawn from the **real widget tree** (the same Flutter screens the app
runs) in a test, with the Roboto font, fictional data, no map tiles, no status bar and no
device frame. They are **not** screenshots of a phone. Apple (guideline 2.3.3) and Google
(Metadata policy) require that screenshots show the app in actual use and do not
mislead. The renders are truthful in content (same screens, same layout logic, fake people), but:

- recommended: capture the final set **once from a real device or emulator/simulator** and
  use the generated files only as the layout reference or a fallback; and
- never add features to a caption that the screen does not show; the map screen is not
  rendered here (it needs tiles) so a real capture of the map is the most important one to add.

The older Play listing images in `assets/google-play/upload/` were made on a Mac with the
older tool `app/tool/store_assets_capture_test.dart`. They still show OpenFamily (the name before the rename)
and the pre-redesign screens, so replace them with the output of `scripts/store-assets.sh` (or real
captures) before the next listing update.

## Capturing real screenshots

Use the demo server (`docs/release/DEMO_SERVER.md`) so every image shows fictional people.

### Android phone and tablet emulator (adb)

```
# create/start an emulator with the right size, e.g. Pixel 8 (1080x2400) or Pixel Tablet
adb devices
adb shell settings put global sys_ui_demo_allowed 1            # optional demo mode
adb shell am broadcast -a com.android.systemui.demo -e command enter
adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0941
adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4
adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
adb exec-out screencap -p > people.png
adb shell am broadcast -a com.android.systemui.demo -e command exit
```

Play wants phone images of at least 1080 px on the short side for the best placement; use a
1080 x 2400 device and let the compose step (or an image editor) add captions, or upload
uncaptioned images.

### Wear OS round (emulator)

```
# Wear OS 4/5 "Large Round" emulator (454 x 454)
adb -e exec-out screencap -p > dist/store-assets/raw-watch/wear-people.png
```

Pair the emulator with the phone emulator (Wear OS app in Android Studio, Device Manager) so the
watch shows the demo circle. `scripts/store-assets.sh --compose-only` then crops each
`wear-*.png` to a centred square and writes 512 x 512 files into `google-play/wear-os-512x512/`.
Play requires 1:1 images, at least 384 px, **without** a device frame.

### iPhone and iPad (Xcode simulator, needs a Mac)

```
xcrun simctl list devices available                       # find "iPhone 16 Pro Max", "iPad Pro 13-inch (M4)"
xcrun simctl boot "iPhone 16 Pro Max"
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4
xcrun simctl io booted screenshot --type=png people.png    # 1320 x 2868 on the 6.9" simulators
xcrun simctl status_bar booted clear
```

Install the unsigned simulator build or run from Xcode (`flutter run -d <simulator>`), sign in to the demo
server and navigate to each screen. Device names change with Xcode versions; take the model that
Apple's page lists for 6.9" and 13".

### Apple Watch (simulator)

```
xcrun simctl boot "Apple Watch Series 10 (46mm)"
xcrun simctl io booted screenshot --type=png dist/store-assets/raw-watch/applewatch-people.png
```

Only needed if the watch app ships (see [App Store, Apple Watch](APP_STORE.md#apple-watch)). Series 10/11 46 mm is 416 x 496;
Ultra models differ; each size you provide must match an Apple slot exactly. The compose step fits the capture into 416 x 496 with black bars if the size differs; replace those by exact captures.

## Review checklist for every image

- [ ] Shows only fictional people and places; no real name, address, email or server URL.
- [ ] Shows features that exist in the version being submitted (no driving sensors on iPhone).
- [ ] Caption text is readable and in the listing language.
- [ ] No transparency, correct pixel size, correct order (people first).
- [ ] The same app version and theme the store shows in the listing.
