import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uata_app/core/companion.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/pairing_screen.dart';
import 'package:uata_app/ui/screens/settings_screen.dart';

import 'fake_engine.dart';

final fp = 'ab' * 32;

void main() {
  group('pairing link', () {
    test('parses the QR content', () {
      final l = PairingLink.tryParse('uata://pair?h=192.168.1.20&p=8766&fp=${fp.toUpperCase()}&c=Xy_9')!;
      expect(l.host, '192.168.1.20');
      expect(l.port, 8766);
      expect(l.fingerprint, fp);
      expect(l.code, 'Xy_9');
    });

    test('rejects anything incomplete or foreign', () {
      for (final bad in [
        'https://evil.example/pair?h=1&p=1&fp=$fp&c=x',
        'uata://pair?h=1.2.3.4&p=8766&c=x',
        'uata://pair?h=1.2.3.4&p=8766&fp=abc&c=x',
        'uata://pair?h=1.2.3.4&p=port&fp=$fp&c=x',
        'uata://pair?h=1.2.3.4&p=8766&fp=$fp',
        'not a link',
      ]) {
        expect(PairingLink.tryParse(bad), isNull, reason: bad);
      }
    });

    test('pairing is stored in secure storage and can be cleared', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      expect(await CompanionStore.load(), isNull);
      await CompanionStore.save(CompanionPairing(host: 'h', port: 1, fingerprint: fp, token: 't'));
      expect((await CompanionStore.load())!.baseUrl.toString(), 'https://h:1');
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty); // token not in plain storage
      expect(await const FlutterSecureStorage().read(key: 'uata.companion.pairing'), contains('"token":"t"'));
      await CompanionStore.clear();
      expect(await CompanionStore.load(), isNull);
    });

    test('a pairing left in plain storage by an older version is moved to secure storage', () async {
      SharedPreferences.setMockInitialValues(
          {'uata.companion.pairing': '{"host":"h","port":2,"fingerprint":"$fp","token":"old"}'});
      FlutterSecureStorage.setMockInitialValues({});
      expect((await CompanionStore.load())!.token, 'old');
      expect((await SharedPreferences.getInstance()).getString('uata.companion.pairing'), isNull);
      expect(await const FlutterSecureStorage().read(key: 'uata.companion.pairing'), contains('"token":"old"'));
    });
  });

  group('pairing screen (phone)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    testWidgets('invalid link shows an error and does not call the computer', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: PairingScreen(
              allowCamera: false,
              onPaired: (_) {},
              pair: (l, n) async {
                calls++;
                throw StateError('unreachable');
              })));
      await tester.enterText(find.byKey(const Key('pair_link')), 'hello');
      await tester.tap(find.byKey(const Key('btn_pair')));
      await tester.pumpAndSettle();
      expect(find.text(tr('ar', 'pair_invalid_link')), findsOneWidget);
      expect(calls, 0);
    });

    testWidgets('valid link pairs, saves and continues', (tester) async {
      CompanionPairing? done;
      String? sentName;
      await tester.pumpWidget(MaterialApp(
          home: PairingScreen(
              allowCamera: false,
              onPaired: (p) => done = p,
              pair: (l, n) async {
                sentName = n;
                return CompanionPairing(host: l.host, port: l.port, fingerprint: l.fingerprint, token: 'dev-token');
              })));
      await tester.enterText(find.byKey(const Key('pair_name')), 'Tablet');
      await tester.enterText(find.byKey(const Key('pair_link')), 'uata://pair?h=10.0.0.5&p=8766&fp=$fp&c=abc');
      await tester.tap(find.byKey(const Key('btn_pair')));
      await tester.pumpAndSettle();
      expect(done!.token, 'dev-token');
      expect(sentName, 'Tablet');
      expect((await CompanionStore.load())!.host, '10.0.0.5');
    });

    testWidgets('computer refusal is shown', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: PairingScreen(
              allowCamera: false,
              onPaired: (_) {},
              pair: (l, n) async => throw EngineException(401, 'wrong pairing code'))));
      await tester.enterText(find.byKey(const Key('pair_link')), 'uata://pair?h=10.0.0.5&p=8766&fp=$fp&c=abc');
      await tester.tap(find.byKey(const Key('btn_pair')));
      await tester.pumpAndSettle();
      expect(find.textContaining('wrong pairing code'), findsOneWidget);
    });
  });

  group('settings', () {
    Future<void> big(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('desktop: turn on, show the pairing QR, revoke a device', (tester) async {
      await big(tester);
      final e = FakeEngine();
      e.companionDevices = [
        {'id': 7, 'name': 'Basim phone', 'created_at': 'x', 'last_seen_at': null, 'revoked_at': null}
      ];
      final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
      await state.init();
      await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_pair_device')), findsNothing); // off by default
      await tester.tap(find.byKey(const Key('companion_toggle')));
      await tester.pumpAndSettle();
      expect(e.settings['companion_enabled'], true);
      await tester.tap(find.byKey(const Key('btn_pair_device')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('CODE123'), findsOneWidget);
      expect(e.pairingsCreated, 1);
      await tester.tap(find.text(tr('ar', 'close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('revoke_7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_revoke')));
      await tester.pumpAndSettle();
      expect(e.companionDevices.single['revoked_at'], isNotNull);
      expect(find.byKey(const Key('device_7')), findsNothing);
    });

    testWidgets('phone: settings live on the computer; unpair asks first', (tester) async {
      await big(tester);
      var unpaired = false;
      final state = AppState(
        engine: FakeEngine(),
        window: FakeWindow(),
        pollInterval: null,
        companion: CompanionPairing(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't'),
        onUnpair: () async => unpaired = true,
      );
      await state.init();
      await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
      await tester.pumpAndSettle();
      expect(find.text(tr('ar', 'companion_settings_on_computer')), findsOneWidget);
      expect(find.byKey(const Key('btn_wipe')), findsNothing);
      expect(find.byKey(const Key('btn_backup')), findsNothing);
      await tester.tap(find.byKey(const Key('btn_unpair')));
      await tester.pumpAndSettle();
      expect(unpaired, false);
      await tester.tap(find.byKey(const Key('confirm_unpair')));
      await tester.pumpAndSettle();
      expect(unpaired, true);
    });
  });
}
