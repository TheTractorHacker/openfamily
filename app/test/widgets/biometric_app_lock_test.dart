import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:openfamily/services/biometric_service.dart';
import 'package:openfamily/widgets/biometric_app_lock.dart';

void main() {
  testWidgets('does not lock a session when biometric unlock is disabled',
      (WidgetTester tester) async {
    final _MemoryPreferenceStore store = _MemoryPreferenceStore(false);
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: store,
      ),
    );

    expect(find.text('OpenFamily is locked'), findsNothing);
    expect(find.text('Private map'), findsOneWidget);
    expect(authenticator.authenticationCalls, 0);
  });

  testWidgets('unlocks a valid session after biometric authentication',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(true),
      ),
    );

    expect(find.text('OpenFamily is locked'), findsNothing);
    expect(authenticator.authenticationCalls, 1);
  });

  testWidgets('keeps failed authentication covered with retry and logout',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator =
        _FakeAuthenticator(authenticated: false);
    int logoutCalls = 0;

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(true),
      ),
      onLogout: () async {
        logoutCalls++;
      },
    );

    expect(find.text('OpenFamily is locked'), findsOneWidget);
    expect(
      find.text(
          'Biometric authentication was not completed. Please try again.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();
    expect(authenticator.authenticationCalls, 2);

    await tester.tap(find.text('Log out instead'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 1);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('clears a stale opt-in when there is no valid session',
      (WidgetTester tester) async {
    final _MemoryPreferenceStore store = _MemoryPreferenceStore(true);
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: store,
      ),
      hasStoredSession: false,
    );

    expect(store.enabled, isFalse);
    expect(authenticator.authenticationCalls, 0);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('fails closed when secure session storage cannot be read',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(true),
      ),
      storedSessionError: StateError('secure storage unavailable'),
    );

    expect(authenticator.authenticationCalls, 1);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('fails closed when the biometric preference cannot be read',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(
          true,
          readError: StateError('preferences unavailable'),
        ),
      ),
    );

    expect(authenticator.authenticationCalls, 0);
    expect(find.text('OpenFamily is locked'), findsOneWidget);
    expect(find.text('Could not read biometric settings. Retry or log out.'),
        findsOneWidget);
  });

  testWidgets('keeps content covered when logout fails',
      (WidgetTester tester) async {
    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: _FakeAuthenticator(authenticated: false),
        preferenceStore: _MemoryPreferenceStore(true),
      ),
      onLogout: () async => throw StateError('logout failed'),
    );

    await tester.tap(find.text('Log out instead'));
    await tester.pumpAndSettle();

    expect(find.text('OpenFamily is locked'), findsOneWidget);
    expect(find.text('Could not log out safely. Please try again.'),
        findsOneWidget);
  });

  testWidgets('authenticates again after the app resumes',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(true),
      ),
    );
    expect(authenticator.authenticationCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(authenticator.authenticationCalls, 2);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('losing window focus alone (screenshot toolbar) does not lock',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();

    await _pumpLock(
      tester,
      service: BiometricService(
        authenticator: authenticator,
        preferenceStore: _MemoryPreferenceStore(true),
      ),
    );
    expect(authenticator.authenticationCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('OpenFamily is locked'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(authenticator.authenticationCalls, 1);
  });

  testWidgets('a foreground session check cannot uncover a backgrounded app',
      (WidgetTester tester) async {
    final Completer<bool> firstSessionCheck = Completer<bool>();
    int sessionChecks = 0;
    final BiometricService service = BiometricService(
      authenticator: _FakeAuthenticator(),
      preferenceStore: _MemoryPreferenceStore(true),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricAppLock(
          service: service,
          hasStoredSession: () {
            sessionChecks++;
            return sessionChecks == 1
                ? firstSessionCheck.future
                : Future<bool>.value(false);
          },
          onLogout: () async {},
          child: const Scaffold(body: Text('Private map')),
        ),
      ),
    );
    await tester.pump();
    expect(sessionChecks, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    firstSessionCheck.complete(false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Private map'), findsOneWidget);
  });

  testWidgets('relocks after backgrounding during a Settings auth prompt',
      (WidgetTester tester) async {
    final Completer<bool> settingsPrompt = Completer<bool>();
    final _FakeAuthenticator authenticator = _FakeAuthenticator(
      pendingCall: 2,
      pendingResult: settingsPrompt,
    );
    final BiometricService service = BiometricService(
      authenticator: authenticator,
      preferenceStore: _MemoryPreferenceStore(true),
    );

    await _pumpLock(tester, service: service);
    expect(authenticator.authenticationCalls, 1);

    final Future<BiometricAuthenticationResult> externalAuthentication =
        service.authenticate(
      localizedReason: 'Confirm a Settings change.',
    );
    for (int i = 0; i < 5 && authenticator.authenticationCalls < 2; i++) {
      await tester.pump();
    }
    expect(service.isAuthenticating, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    settingsPrompt.complete(false);
    await externalAuthentication;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    // The failed Settings prompt cannot count as the foreground unlock. The
    // root gate performs its own third authentication before uncovering.
    expect(authenticator.authenticationCalls, 3);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('root auth cannot uncover after backgrounding mid-prompt',
      (WidgetTester tester) async {
    final Completer<bool> rootPrompt = Completer<bool>();
    final _FakeAuthenticator authenticator = _FakeAuthenticator(
      pendingCall: 1,
      pendingResult: rootPrompt,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricAppLock(
          service: BiometricService(
            authenticator: authenticator,
            preferenceStore: _MemoryPreferenceStore(true),
          ),
          hasStoredSession: () async => true,
          onLogout: () async {},
          child: const Scaffold(body: Text('Private map')),
        ),
      ),
    );
    for (int i = 0; i < 5 && authenticator.authenticationCalls < 1; i++) {
      await tester.pump();
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    rootPrompt.complete(true);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(authenticator.authenticationCalls, 2);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets(
      'inactive auth success is discarded if the app pauses before resuming',
      (WidgetTester tester) async {
    final Completer<bool> rootPrompt = Completer<bool>();
    final _FakeAuthenticator authenticator = _FakeAuthenticator(
      pendingCall: 1,
      pendingResult: rootPrompt,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricAppLock(
          service: BiometricService(
            authenticator: authenticator,
            preferenceStore: _MemoryPreferenceStore(true),
          ),
          hasStoredSession: () async => true,
          onLogout: () async {},
          child: const Scaffold(body: Text('Private map')),
        ),
      ),
    );
    for (int i = 0; i < 5 && authenticator.authenticationCalls < 1; i++) {
      await tester.pump();
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    rootPrompt.complete(true);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(authenticator.authenticationCalls, 2);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });

  testWidgets('grace period keeps the app unlocked on a quick resume',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();
    final BiometricService service = BiometricService(
      authenticator: authenticator,
      preferenceStore: _MemoryPreferenceStore(true),
      graceStore: _MemoryLockGraceStore(const Duration(minutes: 5)),
    );

    await _pumpLock(tester, service: service);
    expect(authenticator.authenticationCalls, 1);
    expect(find.text('OpenFamily is locked'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));

    // Inside the grace window the app is still unlocked and no new
    // authentication has been queued.
    expect(find.text('OpenFamily is locked'), findsNothing);
    expect(find.text('Private map'), findsOneWidget);
    expect(authenticator.authenticationCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(authenticator.authenticationCalls, 1);
    expect(find.text('Private map'), findsOneWidget);
  });

  testWidgets('grace expiry while backgrounded locks and re-authenticates',
      (WidgetTester tester) async {
    final _FakeAuthenticator authenticator = _FakeAuthenticator();
    final BiometricService service = BiometricService(
      authenticator: authenticator,
      preferenceStore: _MemoryPreferenceStore(true),
      graceStore: _MemoryLockGraceStore(const Duration(minutes: 5)),
    );

    await _pumpLock(tester, service: service);
    expect(authenticator.authenticationCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    // Past the grace window while still backgrounded: the cover lands (the
    // test binding, like the platform, stops producing frames once paused,
    // so the cover itself is not renderable mid-pause).
    await tester.pump(const Duration(minutes: 6));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(authenticator.authenticationCalls, 2);
    expect(find.text('OpenFamily is locked'), findsNothing);
  });
}

Future<void> _pumpLock(
  WidgetTester tester, {
  required BiometricService service,
  bool hasStoredSession = true,
  Object? storedSessionError,
  Future<void> Function()? onLogout,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BiometricAppLock(
        service: service,
        hasStoredSession: () async {
          if (storedSessionError != null) throw storedSessionError;
          return hasStoredSession;
        },
        onLogout: onLogout ?? () async {},
        child: const Scaffold(body: Text('Private map')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MemoryPreferenceStore implements BiometricPreferenceStore {
  _MemoryPreferenceStore(
    this.enabled, {
    this.readError,
  });

  bool enabled;
  final Object? readError;

  @override
  Future<bool> isEnabled() async {
    if (readError != null) throw readError!;
    return enabled;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    this.enabled = enabled;
    return true;
  }
}

class _MemoryLockGraceStore implements LockGraceStore {
  _MemoryLockGraceStore(this.grace);

  Duration grace;

  @override
  Future<Duration> readGrace() async => grace;

  @override
  Future<bool> writeGrace(Duration grace) async {
    this.grace = grace;
    return true;
  }
}

class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator({
    this.authenticated = true,
    this.pendingCall,
    this.pendingResult,
  });

  final bool authenticated;
  final int? pendingCall;
  final Completer<bool>? pendingResult;
  int authenticationCalls = 0;

  @override
  Future<bool> get canCheckBiometrics async => true;

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async =>
      const <BiometricType>[BiometricType.fingerprint];

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required AuthenticationOptions options,
  }) async {
    authenticationCalls++;
    if (authenticationCalls == pendingCall && pendingResult != null) {
      return pendingResult!.future;
    }
    return authenticated;
  }

  @override
  Future<bool> stopAuthentication() async => true;
}
