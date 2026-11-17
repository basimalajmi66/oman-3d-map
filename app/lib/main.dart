import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'core/engine_api.dart';
import 'core/engine_locator.dart';
import 'core/http_engine_api.dart';
import 'core/window_controller.dart';
import 'state/app_state.dart';
import 'ui/panel/floating_panel.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final window = await WindowController.create();
  final locator = EngineLocator();
  final port = Platform.environment['UATA_PORT'] ?? '8765';
  final EngineApi engine = HttpEngineApi(
    baseUrl: Uri.parse('http://127.0.0.1:$port'),
    tokenProvider: locator.readToken,
  );
  await locator.ensureRunning(engine);
  final state = AppState(engine: engine, window: window);
  await state.init();
  runApp(UataApp(state: state));
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
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: app.themeMode,
          builder: (context, child) => Directionality(
            textDirection: app.isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: const FloatingPanel(),
        );
      }),
    );
  }
}
