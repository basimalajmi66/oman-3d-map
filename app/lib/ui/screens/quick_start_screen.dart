import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../data/market_data.dart';
import '../../data/quick_start.dart';
import '../../state/app_state.dart';
import '../theme.dart';

typedef QuickStartRunner = Future<QuickStartResult> Function(
    EngineApi api, MarketAsset asset, int timeframeSec, double payout, void Function(QuickStartStage, double) onStage);

Future<QuickStartResult> defaultRunner(
    EngineApi api, MarketAsset asset, int tf, double payout, void Function(QuickStartStage, double) onStage) async {
  final client = MarketDataClient();
  try {
    return await runQuickStart(api, client, asset, tf, payout: payout, onStage: onStage);
  } finally {
    client.close();
  }
}

/// "Quick start": download real prices, add classic strategies as drafts, test them all, show honest results.
class QuickStartScreen extends StatefulWidget {
  const QuickStartScreen({super.key, this.runner = defaultRunner});
  final QuickStartRunner runner;
  @override
  State<QuickStartScreen> createState() => _QuickStartScreenState();
}

class _QuickStartScreenState extends State<QuickStartScreen> {
  MarketAsset _asset = marketAssets.first;
  double _payout = 0.85;
  bool _consent = false;
  QuickStartStage? _stage;
  double _progress = 0;
  QuickStartResult? _result;
  String? _error;
  final _approved = <int>{};

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    _consent = AppScope.read(context).settings['external_data_sources_allowed'] == true;
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _result = null;
      _stage = QuickStartStage.downloading;
    });
    try {
      if (app.settings['external_data_sources_allowed'] != true) {
        await app.updateSettings({'external_data_sources_allowed': true}); // the user ticked the consent box
      }
      final tf = app.settings['candle_timeframe_sec'] as int? ?? 30;
      final r = await widget.runner(app.engine, _asset, tf, _payout, (s, p) {
        if (mounted) {
          setState(() {
            _stage = s;
            _progress = p;
          });
        }
      });
      if (mounted) setState(() => _result = r);
    } on MarketDataException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _stage = null);
    }
  }

  Future<void> _approve(StrategyOutcome o) async {
    await runWithFeedback(context, () async {
      await app.engine.approveStrategy(o.strategyId);
      if (mounted) setState(() => _approved.add(o.strategyId));
    }, successKey: 'approved');
  }

  String _pct(Object? v) => v == null ? '—' : '${((v as num) * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final busy = _stage != null;
    final tf = app.settings['candle_timeframe_sec'] as int? ?? 30;
    return Scaffold(
      appBar: AppBar(title: Text(app.t('qs_title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(app.t('qs_intro')),
        const SizedBox(height: 12),
        DropdownButtonFormField<MarketAsset>(
          key: const Key('qs_asset'),
          initialValue: _asset,
          decoration: InputDecoration(labelText: app.t('qs_asset')),
          items: [for (final a in marketAssets) DropdownMenuItem(value: a, child: Text(app.lang == 'ar' ? a.ar : a.en))],
          onChanged: busy ? null : (a) => setState(() => _asset = a!),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<double>(
          key: const Key('qs_payout'),
          initialValue: _payout,
          decoration: InputDecoration(labelText: app.t('qs_payout'), helperText: app.t('qs_payout_hint')),
          items: [for (final p in const [0.70, 0.75, 0.80, 0.82, 0.85, 0.88, 0.90, 0.92, 0.95]) DropdownMenuItem(value: p, child: Text('${(p * 100).round()}%'))],
          onChanged: busy ? null : (p) => setState(() => _payout = p!),
        ),
        const SizedBox(height: 8),
        Text('${app.t('candle_tf')}: ${tf}s  ·  ${app.t('qs_days')}: ${defaultDays(_asset, tf)}'),
        CheckboxListTile(
          key: const Key('qs_consent'),
          contentPadding: EdgeInsets.zero,
          value: _consent,
          onChanged: busy ? null : (v) => setState(() => _consent = v ?? false),
          title: Text(app.t('qs_consent')),
          subtitle: Text(app.t('qs_consent_hint')),
        ),
        FilledButton.icon(
          key: const Key('qs_start'),
          onPressed: busy || !_consent ? null : _start,
          icon: const Icon(Icons.rocket_launch_outlined),
          label: Text(app.t('qs_start')),
        ),
        if (busy) ...[
          const SizedBox(height: 16),
          Text(app.t('qs_stage_${_stage!.name}')),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _stage == QuickStartStage.downloading || _stage == QuickStartStage.testing ? _progress : null),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('${app.t('qs_failed')}: $_error', key: const Key('qs_error'), style: const TextStyle(color: SignalColors.sell)),
          ),
        if (_result != null) ..._results(app, _result!),
      ]),
    );
  }

  List<Widget> _results(AppState app, QuickStartResult r) {
    final passed = r.outcomes.where((o) => o.qualifies).length;
    return [
      const Divider(height: 32),
      Text('${app.t('qs_data_ready')}: ${r.dataset['name']} (${r.dataset['rows']})', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(passed == 0 ? app.t('qs_none_passed') : app.t('qs_some_passed').replaceAll('{n}', '$passed'), key: const Key('qs_summary')),
      const SizedBox(height: 8),
      for (final o in r.outcomes)
        Card(
          key: Key('qs_result_${o.strategyId}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(o.qualifies ? Icons.check_circle : Icons.cancel_outlined, color: o.qualifies ? SignalColors.buy : SignalColors.wait),
                const SizedBox(width: 8),
                Expanded(child: Text(o.name, style: const TextStyle(fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 4),
              Text(o.idea, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Text('${app.t('qs_oos_trades')}: ${o.oos['trades']}  ·  ${app.t('qs_win_rate')}: ${_pct(o.oos['win_rate'])}'
                  '${o.oos['win_rate_ci95'] is List ? ' (${_pct((o.oos['win_rate_ci95'] as List)[0])}–${_pct((o.oos['win_rate_ci95'] as List)[1])})' : ''}'
                  '  ·  ${app.t('qs_breakeven')}: ${_pct(o.oos['breakeven_win_rate'])}'),
              Text('${app.t('qs_expectancy')}: ${o.oos['expectancy_per_trade'] ?? '—'}'),
              if (!o.qualifies)
                Text([for (final g in (o.result['gate_reasons'] as List)) app.t('g_$g')].join(' · '),
                    style: const TextStyle(color: SignalColors.wait)),
              if (o.qualifies)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: _approved.contains(o.strategyId)
                      ? Chip(label: Text(app.t('approved')))
                      : FilledButton(key: Key('qs_approve_${o.strategyId}'), onPressed: () => _approve(o), child: Text(app.t('approve_strategy'))),
                ),
            ]),
          ),
        ),
      const SizedBox(height: 8),
      Text(app.t('qs_honesty'), style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}
