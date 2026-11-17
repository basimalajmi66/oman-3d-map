import 'package:material_ui/material_ui.dart';

import '../core/engine_api.dart';
import '../state/app_state.dart';

class SignalColors {
  static const buy = Color(0xFF16A34A);
  static const sell = Color(0xFFDC2626);
  static const wait = Color(0xFFF59E0B);
}

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0E7490), brightness: b);
  return ThemeData(
    colorScheme: scheme,
    brightness: b,
    visualDensity: VisualDensity.compact,
    fontFamilyFallback: const ['Segoe UI', 'Tahoma', 'Noto Sans Arabic', 'Roboto'],
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
  );
}

/// Run an engine action and show its error (or a success message) in a snackbar.
Future<bool> runWithFeedback(BuildContext context, Future<void> Function() action, {String? successKey}) async {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    await action();
    if (successKey != null) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(app.t(successKey))));
    }
    return true;
  } on EngineException catch (e) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text('${app.t('error')}: ${e.message}'),
      backgroundColor: errorColor,
    ));
    return false;
  }
}

String fmtDate(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String fmtBytes(num? b) {
  if (b == null) return '—';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
