# Apple Watch app (developer notes)

Design, message table, snapshot JSON, privacy, signing and the list of things the first CI run
must prove: [WATCH_APPS_APPLE.md](../design/WATCH_APPS_APPLE.md). Read its status line first:
the Swift and Xcode parts were written without a Mac and have never been compiled.

Contract (snapshot JSON, commands) and the shared Dart bridge: [WATCH_APPS.md](../design/WATCH_APPS.md).

Quick map:

- Watch app: `app/ios/OrbitlyWatch/` (SwiftUI, watchOS 9, no dependencies).
- iPhone bridge: `app/ios/Runner/WatchBridge.swift`, driven by the same Dart
  `watch_bridge.dart` as Android (`WatchBridge.platformSupported` is true on both).
- To add a command: extend `WatchCmd` and `WatchBridge.handleCommand` (Dart), then add a
  `CommandButton(cmd:arg:)` on the watch. The watch gets the result from `lastCommand`.
- Tests: `app/test/services/watch/watch_bridge_test.dart` (shared, fake transport).
- Remove the target if it breaks the iPhone build: `python3 scripts/ios-watch-target.py disable`.
- CI: job `watchos` in `.github/workflows/test.yml` (non-blocking for now).
