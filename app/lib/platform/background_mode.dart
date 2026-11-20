/// Background mode (Android): a visible foreground service keeps paper trading running while the app is closed and
/// sends an alert the moment an approved strategy gives a fresh signal. It never trades: the alert says what the
/// strategy sees; deciding and executing (on any account) stays with the user.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import '../core/engine_api.dart';
import '../data/market_data.dart';
import '../data/paper_trading.dart';
import '../engine/local/local_engine_api.dart';
import '../l10n/strings.dart';

/// How often the service looks for newly closed candles. Downloads happen only when a candle has closed.
const backgroundCheckMs = 15000;

/// Texts of the alerts (pure, tested).
String signalTitle(String lang, PaperEvent e) {
  final asset = marketAssets.firstWhere((a) => a.symbol == e.session.asset, orElse: () => marketAssets.first);
  final side = tr(lang, e.side == 'BUY' ? 'bg_buy' : 'bg_sell');
  return '$side · ${lang == 'ar' ? asset.ar : asset.en} · ${durationText(lang, e.durationSec)}';
}

String signalBody(String lang, PaperEvent e) {
  final rows = [for (final t in e.session.trades.values) if (t['strategy_id'] == e.strategyId) t];
  final wins = rows.where((t) => t['outcome'] == 'win').length, losses = rows.where((t) => t['outcome'] == 'loss').length;
  final record = wins + losses == 0
      ? tr(lang, 'bg_no_record')
      : tr(lang, 'bg_record').replaceAll('{n}', '${wins + losses}').replaceAll('{w}', '$wins').replaceAll('{l}', '$losses');
  return '${e.strategyName} — $record ${tr(lang, 'bg_age').replaceAll('{s}', '${e.ageSec}')} ${tr(lang, 'bg_yours')}';
}

String durationText(String lang, int sec) => sec % 60 == 0
    ? (lang == 'ar' ? '${sec ~/ 60} د' : '${sec ~/ 60} min')
    : (lang == 'ar' ? '$sec ث' : '$sec s');

/// Main-isolate side: start / stop / ask.
class BackgroundMode {
  static bool get supported => Platform.isAndroid;

  static Future<bool> get isRunning async => supported && await FlutterForegroundTask.isRunningService;

  static void _init() => FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'uata_background',
          channelName: 'Background mode',
          channelDescription: 'Shows that the assistant is running in the background (paper trading only).',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(backgroundCheckMs),
          autoRunOnBoot: true, // the user turned it on: it comes back after a restart, with its notification
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

  /// Asks for the notification permission (and to be spared by battery optimisation), then starts the service.
  /// Returns an error key, or null when running.
  static Future<String?> start(String lang) async {
    if (!supported) return 'bg_unsupported';
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        return 'bg_need_notifications';
      }
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization(); // optional: refusing only makes checks less regular
    }
    _init();
    if (await FlutterForegroundTask.isRunningService) return null;
    final r = await FlutterForegroundTask.startService(
      serviceId: 7101,
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationTitle: tr(lang, 'bg_running_title'),
      notificationText: tr(lang, 'bg_running_text'),
      notificationButtons: [NotificationButton(id: 'stop', text: tr(lang, 'bg_stop'))],
      callback: backgroundStart,
    );
    return r is ServiceRequestSuccess ? null : 'bg_failed';
  }

  static Future<void> stop() async {
    if (supported && await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void backgroundStart() => FlutterForegroundTask.setTaskHandler(PaperTaskHandler());

/// Runs in the service's own isolate: its own connection to the same on-device database and paper files.
class PaperTaskHandler extends TaskHandler {
  LocalEngine? _engine;
  PaperTrader? _paper;
  final _notes = FlutterLocalNotificationsPlugin();
  bool _busy = false;
  int _alertId = 1;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final dir = (await getApplicationSupportDirectory()).path;
    _engine = await LocalEngine.open('$dir/uata', (v) => rootBundle.loadString('assets/schema/schema_v$v.sql'));
    _paper = PaperTrader('$dir/paper');
    await _notes.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    await _check();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_check());

  Future<void> _check() async {
    final engine = _engine, paper = _paper;
    if (_busy || engine == null || paper == null) return;
    _busy = true;
    try {
      final api = LocalEngineApi(engine);
      final settings = await api.getSettings();
      final lang = settings['language'] as String? ?? 'ar';
      if ((await api.status())['halted'] == true) {
        await _alert(tr(lang, 'bg_halted_title'), tr(lang, 'bg_halted_text'));
        await FlutterForegroundTask.stopService(); // the emergency stop stops everything
        return;
      }
      if (settings['external_data_sources_allowed'] != true) {
        await FlutterForegroundTask.updateService(notificationText: tr(lang, 'bg_no_consent'));
        return;
      }
      await paper.updateAll(api, onEvent: (e) {
        if (e.isSignal) unawaited(_alert(signalTitle(lang, e), signalBody(lang, e)));
      });
      final running = paper.sessions().where((s) => s.status == 'running').toList();
      final dayStart = DateTime.now().toUtc().subtract(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000;
      final today = [for (final s in running) ...s.trades.values.where((t) => (t['time'] as int) >= dayStart)];
      final wins = today.where((t) => t['outcome'] == 'win').length, losses = today.where((t) => t['outcome'] == 'loss').length;
      final now = DateTime.now();
      await FlutterForegroundTask.updateService(
        notificationText: running.isEmpty
            ? tr(lang, 'bg_no_sessions')
            : tr(lang, 'bg_status')
                .replaceAll('{s}', '${running.length}')
                .replaceAll('{n}', '${today.length}')
                .replaceAll('{w}', '$wins')
                .replaceAll('{l}', '$losses')
                .replaceAll('{t}', '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}'),
      );
    } on EngineException {
      // the database is being replaced (restore / wipe stop the service first); the next check retries
    } finally {
      _busy = false;
    }
  }

  Future<void> _alert(String title, String body) => _notes.show(
        id: _alertId++,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails('uata_signals', 'Signals',
              channelDescription: 'A strategy you chose gives a fresh signal (information only, never a trade).',
              importance: Importance.high, priority: Priority.high, styleInformation: BigTextStyleInformation(body)),
        ),
      );

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') unawaited(FlutterForegroundTask.stopService());
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _engine?.close();
    _engine = null;
  }
}
