import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Result of submitting a chart image. Shows exactly what the engine returned —
/// in this build that is WAIT with the reason that chart reading (Phase 3) is
/// not installed, plus the real image dimensions it decoded.
Future<void> showChartResult(BuildContext context, Json result) {
  final app = AppScope.read(context);
  final analysis = (result['analysis'] as Map?)?.cast<String, dynamic>() ?? const {};
  final input = (result['input'] as Map?)?.cast<String, dynamic>() ?? const {};
  final sig = analysis['signal'] as String? ?? 'WAIT';
  final color = switch (sig) { 'BUY' => SignalColors.buy, 'SELL' => SignalColors.sell, _ => SignalColors.wait };
  final reason = analysis['reason_code'] as String?;
  final basis = analysis['data_basis'] as String?;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(app.t('chart_result')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          key: const Key('chart_result_signal'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          child: Text(app.t(sig.toLowerCase()), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        if (reason != null) Text(app.t('reason_$reason')),
        const SizedBox(height: 8),
        Text('${app.t('image_size')}: ${input['width']}×${input['height']}'),
        Text('${app.t('data_basis')}: ${basis == 'image_only' ? app.t('image_only') : basis ?? '—'}'),
        Text('${app.t('added_at')}: ${fmtDate(input['created_at'] as String?)}'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('close')))],
    ),
  );
}
