import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'core/companion.dart';
import 'core/engine_mode.dart';
import 'core/image_prep.dart';
import 'core/engine_api.dart';
import 'core/engine_host.dart';
import 'core/http_engine_api.dart';
import 'core/window_controller.dart';
import 'data/paper_trading.dart';
import 'engine/local/local_host.dart';
import 'platform/android_overlay.dart';
import 'platform/share_intake.dart';
import 'state/app_state.dart';
import 'ui/home/adaptive_home.dart';
import 'ui/overlay/overlay_app.dart';
import 'ui/screens/chart_result.dart';
import 'ui/screens/mode_choice_screen.dart';
import 'ui/screens/pairing_screen.dart';
import 'ui/theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await startApp();
}

/// Builds the app. On a phone / tablet without a pairing, the pairing screen comes first;
/// unpairing calls this again, so the user is back at the pairing screen.
Future<void> startApp() async {
  final window = await WindowController.create();
  CompanionPairing? pairing;
  EngineHost host;
  String? mode;
  if (EngineHost.isCompanionPlatform) {
    mode = await EngineModeStore.load();
    pairing = await CompanionStore.load();
    if (mode == null) {
      if (pairing != null) {
        mode = 'remote'; // paired before modes existed
      } else {
        final chosen = Completer<String>();
        runApp(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: ModeChoiceScreen(onChosen: chosen.complete),
        ));
        mode = await chosen.future;
      }
      await EngineModeStore.save(mode);
    }
    if (mode == 'local') {
      pairing = null;
      host = LocalEngineHost();
    } else {
      if (pairing == null) {
        final done = Completer<CompanionPairing>();
        runApp(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: PairingScreen(onPaired: done.complete),
        ));
        pairing = await done.future;
      }
      host = RemoteEngineHost(pairing);
    }
  } else {
    host = DesktopEngineHost();
  }
  EngineApi engine;
  try {
    engine = await host.connect();
  } on EngineException {
    // Engine failed to start: keep a client so the UI shows "offline" + retry.
    engine = HttpEngineApi(tokenProvider: () async => null);
  }
  late final AppState state;
  Future<void> restartAs(String newMode) async {
    await EngineModeStore.save(newMode);
    state.dispose();
    host.dispose();
    await startApp();
  }

  state = AppState(
    engine: engine,
    window: window,
    overlay: Platform.isAndroid ? AndroidOverlayController() : NoOverlay(),
    companion: pairing,
    onUnpair: () async {
      await CompanionStore.clear();
      state.dispose();
      await startApp();
    },
    onSwitchMode: mode == null ? null : () => restartAs(mode == 'local' ? 'remote' : 'local'),
    paper: PaperTrader('${(await getApplicationSupportDirectory()).path}/paper'),
  );
  await state.init();
  runApp(UataApp(state: state));
  // paper trading catches up now and every two minutes while the app is open (it never executes real trades)
  unawaited(state.paperTick());
  _paperTimer?.cancel();
  _paperTimer = Timer.periodic(const Duration(minutes: 2), (_) => state.paperTick());

  if (EngineHost.isCompanionPlatform) {
    final library = state.has('knowledge');
    if (_share case final share?) {
      share
        ..engine = engine
        ..libraryAvailable = library
        ..prepareImage = ((f) => prepareChartImage(f, state.chartMaxSide))
        ..onOutcomes = (o) => _reportShares(state, o);
    } else {
      _share = ShareIntake(
          engine: engine,
          source: ReceiveSharingIntentSource(),
          libraryAvailable: library,
          prepareImage: (f) => prepareChartImage(f, state.chartMaxSide),
          onOutcomes: (o) => _reportShares(state, o));
      await _share!.start();
    }
  }
}

ShareIntake? _share;
Timer? _paperTimer;

/// Entry point of the Android floating window (separate Flutter engine).
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

void _reportShares(AppState state, List<ShareOutcome> outcomes) {
  for (final o in outcomes) {
    final ctx = navigatorKey.currentContext;
    if (o.kind == ShareOutcomeKind.chartAnalysed && ctx != null && o.result != null) {
      showChartResult(ctx, o.result!);
      continue;
    }
    final key = switch (o.kind) {
      ShareOutcomeKind.chartAnalysed => 'share_chart',
      ShareOutcomeKind.addedToLibrary => 'share_library',
      ShareOutcomeKind.duplicate => 'share_duplicate',
      ShareOutcomeKind.unsupported => 'share_unsupported',
      ShareOutcomeKind.failed => 'share_failed',
    };
    messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('${state.t(key)}: ${o.item.name}${o.error != null ? ' — ${o.error}' : ''}')));
  }
}

class UataApp extends StatelessWidget {
  const UataApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: Builder(builder: (context) {
        final app = AppScope.of(context);
        return MaterialApp(
          title: 'Universal AI Trading Assistant',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: messengerKey,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: app.themeMode,
          builder: (context, child) => Directionality(
            textDirection: app.isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: const AdaptiveHome(),
        );
      }),
    );
  }
}
