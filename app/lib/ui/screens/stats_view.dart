import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';

String _pct(num? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';

/// Statistics dashboard for ONE account type at a time (never mixed), with sample sizes,
/// 95% intervals, breakdowns, the training log and insights (suggestions only).
class StatsView extends StatefulWidget {
  const StatsView({super.key});
  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  String _account = 'demo';
  Json? _d;
  List<Json> _insights = [];

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final d = await app.engine.dashboard(_account);
      final i = await app.engine.insights(_account);
      if (mounted) {
        setState(() {
          _d = d;
          _insights = i;
        });
      }
    });
  }

  String _insightText(Json i) {
    final code = i['code'] as String;
    var tpl = hasString('i_$code') ? app.t('i_$code') : code;
    i.forEach((k, v) {
      final s = v is double && (k.contains('rate') || k == 'overall' || k == 'share') ? _pct(v) : '$v';
      tpl = tpl.replaceAll('{$k}', s);
    });
    return tpl;
  }

  Widget _kpi(String label, String value, {Color? color, Key? key}) => SizedBox(
        width: 150,
        child: Card(
          key: key,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 11)),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            ]),
          ),
        ),
      );

  Widget _group(String key, List<Json> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(app.t('g_$key'), style: const TextStyle(fontWeight: FontWeight.bold)),
        ...rows.map((g) {
          final ci = (g['win_rate_ci95'] as List?)?.cast<num>();
          final enough = g['sufficient_sample'] == true;
          return Text(
            '• ${g['key']}: ${g['wins']}/${g['decided']} · ${_pct(g['win_rate'] as num?)}'
            '${ci != null ? ' (${_pct(ci[0])}–${_pct(ci[1])})' : ''}${enough ? '' : ' — ${app.t('insufficient_sample_label')}'}',
            style: TextStyle(fontSize: 12, color: enough ? null : Colors.grey),
          );
        }),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _d;
    final sig = (d?['signals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final res = (d?['results'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ci = (res['win_rate_ci95'] as List?)?.cast<num>();
    List<Json> list(String k) => ((d?[k] as List?) ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    return ListView(padding: const EdgeInsets.all(12), children: [
      SegmentedButton<String>(
        key: const Key('stats_account'),
        segments: [for (final a in ['simulation', 'demo', 'real']) ButtonSegment(value: a, label: Text(app.t(a)))],
        selected: {_account},
        onSelectionChanged: (v) {
          setState(() => _account = v.first);
          _reload();
        },
      ),
      Text(app.t('accounts_note'), style: const TextStyle(fontSize: 11)),
      if (d != null) ...[
        const SizedBox(height: 8),
        Wrap(children: [
          _kpi(app.t('signals_total'), '${sig['total'] ?? 0}'),
          _kpi('BUY', '${sig['BUY'] ?? 0}', color: SignalColors.buy),
          _kpi('SELL', '${sig['SELL'] ?? 0}', color: SignalColors.sell),
          _kpi('WAIT', '${sig['WAIT'] ?? 0}', color: SignalColors.wait),
        ]),
        Text('${app.t('results_title')} — ${app.t(_account)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        Wrap(children: [
          _kpi(app.t('win'), '${res['wins'] ?? 0}', color: SignalColors.buy, key: const Key('kpi_wins')),
          _kpi(app.t('loss'), '${res['losses'] ?? 0}', color: SignalColors.sell),
          _kpi(app.t('win_rate'), _pct(res['win_rate'] as num?), key: const Key('kpi_win_rate')),
          _kpi(app.t('ci95'), ci == null ? '—' : '${_pct(ci[0])}–${_pct(ci[1])}'),
        ]),
        if (res['sufficient_sample'] != true && (res['decided'] ?? 0) > 0)
          Text(app.t('small_sample'), style: const TextStyle(color: SignalColors.wait)),
        const SizedBox(height: 8),
        Text(app.t('insights'), style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(app.t('insights_note'), style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic)),
        ..._insights.asMap().entries.map((e) => (e.key, e.value)).map((p) {
          final i = p.$2;
          // keys must be unique: two insights can share code and key (e.g. "losses concentrated" for the same value in
          // two fields, or "review" for several strategies) — a repeated key crashed this page
          final base = 'insight_${i['code']}${i['key'] != null ? '_${i['key']}' : ''}';
          final repeated = _insights.take(p.$1).any((o) => 'insight_${o['code']}${o['key'] != null ? '_${o['key']}' : ''}' == base);
          return Padding(
              key: Key(repeated ? '${base}_${p.$1}' : base),
              padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                  (i['code'] as String).contains('worse') || (i['code'] as String).contains('review_suggested') ||
                          (i['code'] as String).contains('inconsistent') || (i['code'] as String).contains('losing') ||
                          (i['code'] as String).contains('concentrated')
                      ? Icons.warning_amber_outlined
                      : Icons.lightbulb_outline,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(_insightText(i), style: const TextStyle(fontSize: 12))),
              ]),
            );
        }),
        for (final k in ['by_strategy', 'by_condition', 'by_asset', 'by_timeframe', 'by_direction', 'by_hour', 'by_confidence', 'by_data_quality'])
          _group(k, list(k)),
        if (list('training_log').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(app.t('training_log'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ...list('training_log').map((r) => Text(
              '• ${r['strategy_name']} v${r['version']} · ${r['dataset']} · ${app.t('trades')} ${r['oos_trades']} · '
              '${app.t('expectancy')} ${r['oos_expectancy']} · ${r['qualifies'] == true ? app.t('qualifies') : app.t('not_qualifies')}',
              style: const TextStyle(fontSize: 12))),
        ],
      ],
    ]);
  }
}
