import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'signal_details.dart' show decisionSteps, strategyEvidence;

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
            if (analysis['repeated'] == true)
              Text(app.t('repeated_note'), key: const Key('repeated_note'), style: const TextStyle(fontSize: 11)),
            if (sig != 'WAIT' && analysis['duration_sec'] != null)
              Text('${app.t('duration')}: ${analysis['duration_sec']}${app.t('seconds')}  ·  '
                  '${app.t('confidence')}: ${analysis['confidence'] == null ? '—' : '${((analysis['confidence'] as num) * 100).round()}% (${app.t('uncalibrated')})'}',
                  key: const Key('chart_result_trade')),
            ...strategyEvidence(app, analysis),
            const SizedBox(height: 8),
            Text('${app.t('image_size')}: \u2066${input['width']}×${input['height']}\u2069'), // isolated: RTL text would show it as height×width
            Text('${app.t('data_basis')}: ${basis == 'image_only' ? app.t('image_only') : basis ?? '—'}'),
            if (quality != null) Text('${app.t('data_quality')}: ${(quality * 100).round()}%', key: const Key('chart_quality')),
            if (reading != null) ..._readingLines(app, reading),
            // verify the reading right where it is described
            if (input['id'] != null) ...[
              const SizedBox(height: 8),
              _AnnotatedPreview(app: app, inputId: input['id'] as int),
            ],
            if (analysis['technical'] is Map) ...technicalLines(app, (analysis['technical'] as Map).cast<String, dynamic>()),
            if (analysis['knowledge'] is List) ...knowledgeLines(app, (analysis['knowledge'] as List).cast<Map>()),
            ...decisionSteps(app, analysis),
            const SizedBox(height: 8),
            Text(app.t('manual_only'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
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

/// Technical analysis section (shared by the result dialog and other views).
List<Widget> technicalLines(AppState app, Json t) {
  if (t['available'] != true) {
    final reason = t['reason'] as String?;
    return [
      const Divider(height: 20),
      Text('${app.t('technical_unavailable')}${reason != null ? ': ${_tr(app, 'tr_', reason)}' : ''}',
          key: const Key('technical_unavailable')),
    ];
  }
  final trend = (t['trend'] as Map?)?.cast<String, dynamic>() ?? const {};
  List<Json> list(String k) => ((t[k] as List?) ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  Widget factorLine(Json f, Color c) => Text(
        '• ${app.t('ind_${f['name']}')} — ${_tr(app, 'c_', f['code'] as String)} (${((f['strength'] as num) * 100).round()}%)',
        style: TextStyle(color: c, fontSize: 12),
      );
  final levels = list('levels');
  final rel = t['units'] == 'relative';
  final disabled = (t['disabled'] as List?)?.length ?? 0;
  final unavailable = (t['unavailable'] as List?)?.length ?? 0;
  final warnings = (t['warnings'] as List?)?.cast<String>() ?? const [];
  return [
    const Divider(height: 20),
    Text(app.t('technical'), style: const TextStyle(fontWeight: FontWeight.bold)),
    Text('${app.t('market_condition')}: ${app.t('mc_${t['market_condition']}')}  ·  '
        '${app.t('trend')}: ${app.t('trend_dir_${trend['direction']}')}', key: const Key('technical_header')),
    const SizedBox(height: 4),
    Text('${app.t('bullish_factors')} (${list('supporting_bullish').length})',
        style: const TextStyle(fontWeight: FontWeight.w600, color: SignalColors.buy)),
    ...list('supporting_bullish').map((f) => factorLine(f, SignalColors.buy)),
    Text('${app.t('bearish_factors')} (${list('supporting_bearish').length})',
        style: const TextStyle(fontWeight: FontWeight.w600, color: SignalColors.sell)),
    ...list('supporting_bearish').map((f) => factorLine(f, SignalColors.sell)),
    if (disabled + unavailable > 0)
      Text('${app.t('factors_disabled')}: $disabled  ·  ${app.t('factors_unavailable')}: $unavailable',
          style: const TextStyle(fontSize: 11)),
    if (levels.isNotEmpty) ...[
      const SizedBox(height: 4),
      Text('${app.t('key_levels')}${rel ? ' ${app.t('units_relative')}' : ''}',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      ...levels.map((l) => Text(
          '• ${app.t(l['kind'] as String)} ${(l['price'] as num).toStringAsPrecision(6)} (${l['touches']} ${app.t('touches')})',
          style: const TextStyle(fontSize: 12))),
    ],
    if (warnings.isNotEmpty)
      Text(warnings.map((w) => _tr(app, 'w_', w)).join(' · '), style: const TextStyle(fontSize: 11, color: SignalColors.wait)),
    const SizedBox(height: 4),
    Text(app.t('technical_not_signal'), style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic)),
  ];
}

/// Approved library passages relevant to this chart (RAG), with source and location.
List<Widget> knowledgeLines(AppState app, List<Map> hits) => [
      const Divider(height: 20),
      Text(app.t('related_knowledge'), style: const TextStyle(fontWeight: FontWeight.bold)),
      if (hits.isEmpty) Text(app.t('no_related_knowledge'), key: const Key('no_related_knowledge'), style: const TextStyle(fontSize: 12)),
      ...hits.map((h) => Padding(
            key: Key('knowledge_${h['item_id']}'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '• ${h['title']}: ${h['snippet']}\n   ${app.t('source')}: ${h['source_title'] ?? '—'}'
              '${h['location'] != null ? ' (${h['location']})' : ''}',
              style: const TextStyle(fontSize: 12),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          )),
    ];
