import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';

String _pct(num? v) => v == null ? '—' : '${(v * 100).round()}%';

/// The 14 decision steps with their status (ok / fail / info).
List<Widget> decisionSteps(AppState app, Json rec) {
  final steps = ((rec['steps'] as List?) ?? const []).cast<Map>();
  if (steps.isEmpty) return const [];
  return [
    const SizedBox(height: 10),
    Text(app.t('decision_steps'), style: const TextStyle(fontWeight: FontWeight.bold)),
    ...steps.map((s) {
      final status = s['status'] as String?;
      final icon = switch (status) {
        'ok' => const Icon(Icons.check_circle, size: 16, color: SignalColors.buy),
        'fail' => const Icon(Icons.cancel, size: 16, color: SignalColors.sell),
        _ => const Icon(Icons.info_outline, size: 16),
      };
      final name = hasString('step_${s['name']}') ? app.t('step_${s['name']}') : '${s['name']}';
      return Padding(
        key: Key('step_${s['n']}'),
        padding: const EdgeInsets.only(top: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          icon,
          const SizedBox(width: 6),
          Expanded(child: Text('${s['n']}. $name${(s['detail'] ?? '') != '' ? ' — ${s['detail']}' : ''}',
              style: const TextStyle(fontSize: 12))),
        ]),
      );
    }),
  ];
}

/// Out-of-sample evidence of the strategy behind a signal.
List<Widget> strategyEvidence(AppState app, Json rec) {
  final st = (rec['strategy'] as Map?)?.cast<String, dynamic>();
  if (st == null) return const [];
  final ci = (st['oos_win_rate_ci95'] as List?)?.cast<num>();
  return [
    const SizedBox(height: 10),
    Text(app.t('strategy_evidence'), key: const Key('strategy_evidence'), style: const TextStyle(fontWeight: FontWeight.bold)),
    Text('${st['name']} (${app.t('version')} ${st['version']})'),
    Text('${app.t('trades')}: ${st['oos_trades']} · ${app.t('win_rate')}: ${_pct(st['oos_win_rate'] as num?)}'
        '${ci != null ? ' (${app.t('ci95')} ${_pct(ci[0])}–${_pct(ci[1])})' : ''}', style: const TextStyle(fontSize: 12)),
    Text('${app.t('expectancy')}: ${st['oos_expectancy']}  ·  '
        '${app.t(st['significant_edge'] == true ? 'significant_edge' : 'no_significant_edge')}',
        style: const TextStyle(fontSize: 12)),
    ...((st['conditions'] as List?) ?? const []).map((c) => Text('• $c', style: const TextStyle(fontSize: 12))),
  ];
}

/// Shows everything behind the current recommendation (or a logged signal):
/// type, reasons, supporting / opposing factors, data quality, confidence,
/// duration, strategy evidence and the 14 decision steps.
Future<void> showSignalDetails(BuildContext context, {Json? signal}) {
  final app = AppScope.read(context);
  final rec = signal ?? app.recommendation;
  final sig = (rec['signal'] as String?) ?? 'WAIT';
  final reasonCode = rec['reason_code'] as String?;
  final reasons = <String>[
    if (reasonCode != null && hasString('reason_$reasonCode')) app.t('reason_$reasonCode'),
    ...((rec['reasons'] as List?)?.cast<String>() ?? const [])
        .map((r) => hasString('reason_$r') ? app.t('reason_$r') : r),
  ];
  List<String> list(String k) => (rec[k] as List?)?.cast<String>() ?? const [];
  final conf = (rec['confidence'] ?? rec['confidence_score']) as num?;
  final calibrated = rec['confidence_calibrated'] == true || rec['confidence_calibrated'] == 1;
  final quality = rec['data_quality'] as num?;
  final strategyName = (rec['strategy'] as Map?)?['name'] ?? rec['strategy_id']?.toString();

  Widget section(String title, List<String> lines) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (lines.isEmpty) Text(app.t('none')) else ...lines.map((l) => Text('• $l')),
        ]),
      );
  Widget kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k)),
          const SizedBox(width: 8),
          // values (e.g. long strategy names) wrap instead of overflowing narrow panels
          Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${app.t('signal_details')}: $sig'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            kv(app.t('confidence'),
                conf == null ? '—' : '${(conf * 100).round()}%${calibrated ? '' : ' (${app.t('uncalibrated')})'}'),
            kv(app.t('duration'), rec['duration_sec'] == null ? '—' : '${rec['duration_sec']}${app.t('seconds')}'),
            kv(app.t('data_quality'), quality == null ? '—' : '${(quality * 100).round()}%'),
            kv(app.t('strategy'), strategyName?.toString() ?? '—'),
            kv(app.t('data_basis'), rec['data_basis'] == 'image_only' ? app.t('image_only') : rec['data_basis']?.toString() ?? '—'),
            section(app.t('reasons'), reasons),
            section(app.t('supporting'), list('supporting')),
            section(app.t('opposing'), list('opposing')),
            ...strategyEvidence(app, rec),
            ...decisionSteps(app, rec),
            const SizedBox(height: 12),
            Text(app.t('confidence_note'), style: const TextStyle(fontSize: 11)),
            Text(app.t('manual_only'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('close')))],
    ),
  );
}
