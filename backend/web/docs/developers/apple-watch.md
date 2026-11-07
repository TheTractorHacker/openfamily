# Apple Watch app (developer notes)

Design, message table, snapshot JSON, privacy, signing and the list of things the first CI run
must prove: [WATCH_APPS_APPLE.md](../design/WATCH_APPS_APPLE.md). Read its status line first:
the Swift and Xcode parts were written without a Mac and have never been compiled.

Quick map:

- Watch app: `app/ios/OrbitlyWatch/` (SwiftUI, watchOS 9, no dependencies).
- iPhone bridge: `app/ios/Runner/WatchBridge.swift` and
  `app/lib/services/watch/watch_bridge_ios.dart`.
- Snapshot and actions: `watch_snapshot.dart`, `watch_actions.dart` (same folder). To add a
  command, add a case in `WatchBridgeIos.handleCommand`, a method on `WatchPhoneActions`, and a
  button on the watch that sends `["cmd": ...]` through `PhoneLink.send`.
- Tests: `app/test/services/watch/watch_bridge_ios_test.dart` (fake channel and fake actions).
- Remove the target if it breaks the iPhone build: `python3 scripts/ios-watch-target.py disable`.
- CI: job `watchos` in `.github/workflows/test.yml` (non-blocking for now).
