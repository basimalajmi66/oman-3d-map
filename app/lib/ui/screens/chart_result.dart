import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Result of reading one chart image: the recommendation (WAIT until the signal
/// engine exists), why, and exactly what the reader extracted — with an option
/// to see the detection drawn on the image so the user can verify it.
Future<void> showChartResult(BuildContext context, Json result) {
  final app = AppScope.read(context);
  final analysis = (result['analysis'] as Map?)?.cast<String, dynamic>() ?? const {};
  final input = (result['input'] as Map?)?.cast<String, dynamic>() ?? const {};
  final reading = (analysis['reading'] as Map?)?.cast<String, dynamic>();
  final sig = analysis['signal'] as String? ?? 'WAIT';
  final color = switch (sig) { 'BUY' => SignalColors.buy, 'SELL' => SignalColors.sell, _ => SignalColors.wait };
  final reason = analysis['reason_code'] as String?;
  final basis = analysis['data_basis'] as String?;
  final quality = analysis['data_quality'] as num?;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(app.t('chart_result')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              key: const Key('chart_result_signal'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
              child: Text(app.t(sig.toLowerCase()), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            if (reason != null) Text(app.t('reason_$reason'), key: const Key('chart_result_reason')),
            const SizedBox(height: 8),
            Text('${app.t('image_size')}: ${input['width']}×${input['height']}'),
            Text('${app.t('data_basis')}: ${basis == 'image_only' ? app.t('image_only') : basis ?? '—'}'),
            if (quality != null) Text('${app.t('data_quality')}: ${(quality * 100).round()}%', key: const Key('chart_quality')),
            if (reading != null) ..._readingLines(app, reading),
            if (input['id'] != null) ...[
              const SizedBox(height: 8),
              _AnnotatedPreview(app: app, inputId: input['id'] as int),
            ],
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('close')))],
    ),
  );
}

String _tr(AppState app, String prefix, String code) => hasString('$prefix$code') ? app.t('$prefix$code') : code;

List<Widget> _readingLines(AppState app, Json r) {
  final abstain = (r['abstain_reasons'] as List?)?.cast<String>() ?? const [];
  final warnings = (r['warnings'] as List?)?.cast<String>() ?? const [];
  final tf = r['timeframe_sec'] as int?;
  final mismatch = tf != null && app.settings['candle_timeframe_sec'] != null && tf != app.settings['candle_timeframe_sec'];
  final lastDir = r['last_closed_direction'] as String?;
  final lastClose = r['last_closed_close'];
  return [
    const Divider(height: 20),
    Text(app.t('reading'), style: const TextStyle(fontWeight: FontWeight.bold)),
    Text('${app.t('candles_detected')}: ${r['candles']}', key: const Key('reading_candles')),
    Text('${app.t('closed_candles')}: ${r['closed_candles']}  ·  ${app.t('bull_bear')}: ${r['bullish']} / ${r['bearish']}'),
    if (lastDir != null)
      Text('${app.t('last_closed')}: ${app.t(lastDir)}${lastClose != null ? ' @ $lastClose' : ''}'),
    Text(app.t('forming_note'), style: const TextStyle(fontSize: 11)),
    Text('${app.t('prices')}: ${app.t(r['prices_read'] == true ? 'prices_read' : 'prices_not_read')}',
        key: const Key('reading_prices')),
    if (tf != null) Text('${app.t('tf_detected')}: ${r['timeframe_label'] ?? tf}'),
    if (mismatch)
      Text(app.t('tf_mismatch'), key: const Key('tf_mismatch'), style: const TextStyle(color: SignalColors.wait)),
    if (abstain.isNotEmpty) ...[
      const SizedBox(height: 4),
      Text(app.t('abstain_reasons'), style: const TextStyle(fontWeight: FontWeight.w600)),
      ...abstain.map((a) => Text('• ${_tr(app, 'a_', a)}')),
    ],
    if (warnings.isNotEmpty)
      Text(warnings.map((w) => _tr(app, 'w_', w)).join(' · '), style: const TextStyle(fontSize: 11, color: SignalColors.wait)),
  ];
}

class _AnnotatedPreview extends StatefulWidget {
  const _AnnotatedPreview({required this.app, required this.inputId});
  final AppState app;
  final int inputId;
  @override
  State<_AnnotatedPreview> createState() => _AnnotatedPreviewState();
}

class _AnnotatedPreviewState extends State<_AnnotatedPreview> {
  Uint8List? _png;
  String? _error;
  bool _loading = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final b = await widget.app.engine.chartAnnotated(widget.inputId);
      if (mounted) setState(() => _png = Uint8List.fromList(b));
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_png != null) return Image.memory(_png!, key: const Key('annotated_image'));
    if (_error != null) return Text(_error!, style: const TextStyle(fontSize: 11));
    return OutlinedButton.icon(
      key: const Key('show_detection'),
      onPressed: _loading ? null : _load,
      icon: const Icon(Icons.visibility_outlined),
      label: Text(widget.app.t('show_detection')),
    );
  }
}
