import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'core/engine_api.dart';
import 'core/engine_host.dart';
import 'core/http_engine_api.dart';
import 'core/window_controller.dart';
import 'platform/android_overlay.dart';
import 'platform/share_intake.dart';
import 'state/app_state.dart';
import 'ui/home/adaptive_home.dart';
import 'ui/overlay/overlay_app.dart';
import 'ui/screens/chart_result.dart';
import 'ui/theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final window = await WindowController.create();
  final host = EngineHost.forPlatform();
  EngineApi engine;
  try {
    engine = await host.connect();
  } on EngineException {
    // Engine failed to start: keep a client so the UI shows "offline" + retry.
    engine = HttpEngineApi(tokenProvider: () async => null);
  }
  final state = AppState(
    engine: engine,
    window: window,
    overlay: Platform.isAndroid ? AndroidOverlayController() : NoOverlay(),
  );
  await state.init();
  runApp(UataApp(state: state));

  if (Platform.isAndroid || Platform.isIOS) {
    await ShareIntake(engine: engine, source: ReceiveSharingIntentSource(), onOutcomes: (o) => _reportShares(state, o))
        .start();
  }
}

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
