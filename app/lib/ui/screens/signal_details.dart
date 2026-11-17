import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../state/app_state.dart';

/// Shows everything behind the current recommendation (or a logged signal):
/// type, reasons, supporting / opposing factors, data quality, confidence,
/// duration, strategy and data basis.
Future<void> showSignalDetails(BuildContext context, {Json? signal}) {
  final app = AppScope.read(context);
  final rec = signal ?? app.recommendation;
  final sig = (rec['signal'] as String?) ?? 'WAIT';
  final reasonCode = rec['reason_code'] as String?;
  final reasons = <String>[
    ...((rec['reasons'] as List?)?.cast<String>() ?? const []),
    if (reasonCode != null) app.t('reason_$reasonCode'),
  ];
  List<String> list(String k) => (rec[k] as List?)?.cast<String>() ?? const [];
  final conf = (rec['confidence'] ?? rec['confidence_score']) as num?;
  final calibrated = rec['confidence_calibrated'] == true || rec['confidence_calibrated'] == 1;
  final quality = rec['data_quality'] as num?;

  Widget section(String title, List<String> lines) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (lines.isEmpty) Text(app.t('none')) else ...lines.map((l) => Text('• $l')),
        ]),
      );
  Widget kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [Expanded(child: Text(k)), Text(v, style: const TextStyle(fontWeight: FontWeight.w600))]),
      );

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${app.t('signal_details')}: $sig'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          kv(app.t('confidence'),
              conf == null ? '—' : '${(conf * 100).round()}%${calibrated ? '' : ' (${app.t('uncalibrated')})'}'),
          kv(app.t('duration'), rec['duration_sec'] == null ? '—' : '${rec['duration_sec']}${app.t('seconds')}'),
          kv(app.t('data_quality'), quality == null ? '—' : '${(quality * 100).round()}%'),
          kv(app.t('strategy'), rec['strategy_id']?.toString() ?? '—'),
          kv(app.t('data_basis'), rec['data_basis']?.toString() ?? '—'),
          section(app.t('reasons'), reasons),
          section(app.t('supporting'), list('supporting')),
          section(app.t('opposing'), list('opposing')),
          const SizedBox(height: 12),
          Text(app.t('confidence_note'), style: const TextStyle(fontSize: 11)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('close')))],
    ),
  );
}
