import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../engine/local/local_engine_api.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'quick_start_screen.dart';
import 'training_screen.dart' show createTestAndOpen;

/// Search for strategies: hundreds of combinations tried on real prices, the best judged on data the search never
/// saw, with a correction for having tried many. Only the user saves / approves.
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});
  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  final _payout = TextEditingController(text: '88');
  List<Json> _datasets = [];
  int? _datasetId;
  bool _busy = false;
  Json? _report;
  String? _error;

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final tf = app.settings['candle_timeframe_sec'];
    final d = [for (final x in await app.engine.listDatasets()) if (x['is_synthetic'] != 1) x]
      ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    if (!mounted) return;
    setState(() {
      _datasets = d;
      _datasetId = (d.where((x) => x['timeframe_sec'] == tf).firstOrNull ?? d.firstOrNull)?['id'] as int?;
    });
  }

  Future<void> _run() async {
    final engine = app.engine;
    if (engine is! LocalEngineApi || _datasetId == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    try {
      final r = await engine.discoverStrategies(_datasetId!, payout: (double.tryParse(_payout.text) ?? 88) / 100);
      if (mounted) setState(() => _report = r);
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _pct(Object? v) => v == null ? '—' : '${((v as num) * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final r = _report;
    return Scaffold(
      appBar: AppBar(title: Text(app.t('disc_title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(app.t('disc_intro'), key: const Key('disc_intro'))),
        ),
        const SizedBox(height: 8),
        if (_datasets.isEmpty) ...[
          Text(app.t('disc_no_data')),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickStartScreen())),
            icon: const Icon(Icons.rocket_launch_outlined),
            label: Text(app.t('qs_title')),
          ),
        ] else ...[
          DropdownButtonFormField<int>(
            key: const Key('disc_dataset'),
            initialValue: _datasetId,
            isExpanded: true,
            decoration: InputDecoration(labelText: app.t('disc_data')),
            items: [
              for (final d in _datasets)
                DropdownMenuItem(value: d['id'] as int, child: Text('${d['name']} · ${d['rows']} ${app.t('rows')}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _busy ? null : (v) => setState(() => _datasetId = v),
          ),
          TextField(
            controller: _payout,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: app.t('disc_payout'), suffixText: '%'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const Key('disc_run'),
            onPressed: _busy || _datasetId == null ? null : _run,
            icon: const Icon(Icons.travel_explore),
            label: Text(app.t('disc_run')),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(app.t('disc_wait'), textAlign: TextAlign.center),
        ],
        if (_error != null) Text(_error!, style: const TextStyle(color: SignalColors.sell)),
        if (r != null) ...[
          const SizedBox(height: 12),
          Text(
            app.t('disc_summary')
                .replaceAll('{n}', '${r['candidates_tested']}')
                .replaceAll('{p}', '${r['passed_search']}')
                .replaceAll('{f}', '${r['finalists']}')
                .replaceAll('{b}', _pct(r['breakeven_win_rate'])),
            key: const Key('disc_summary'),
          ),
          if ((r['results'] as List).isEmpty)
            Padding(padding: const EdgeInsets.all(12), child: Text(app.t('disc_none'), key: const Key('disc_none'))),
          for (final x in (r['results'] as List).cast<Map>()) _result(app, x.cast<String, dynamic>()),
        ],
      ]),
    );
  }

  Widget _result(AppState app, Json x) {
    final h = (x['holdout'] as Map).cast<String, dynamic>();
    final s = (x['search'] as Map).cast<String, dynamic>();
    final ci = (h['win_rate_ci95'] as List?)?.cast<num>();
    final verdict = x['verdict'] as String;
    final color = switch (verdict) {
      'significant' => SignalColors.buy,
      'positive_maybe_luck' => SignalColors.wait,
      _ => SignalColors.sell,
    };
    final name = (app.lang == 'ar' ? x['name_ar'] : x['name_en']) as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
            Chip(label: Text(app.t('disc_v_$verdict')), backgroundColor: color.withValues(alpha: 0.2), side: BorderSide(color: color)),
          ]),
          Text('${app.t('disc_new_data')}: ${h['trades']} ${app.t('trades')} · ${app.t('win_rate')} ${_pct(h['win_rate'])}'
              '${ci != null ? ' (${_pct(ci[0])}–${_pct(ci[1])})' : ''} · ${app.t('expectancy')} ${h['expectancy_per_trade'] ?? '—'}'),
          Text('${app.t('disc_search_data')}: ${s['trades']} ${app.t('trades')} · ${app.t('win_rate')} ${_pct(s['win_rate'])}',
              style: const TextStyle(fontSize: 12)),
          if (verdict == 'significant' || verdict == 'positive_maybe_luck')
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: Key('disc_save_${x['name_en']}'),
                onPressed: () => createTestAndOpen(context, app, name, (x['definition'] as Map).cast<String, dynamic>()),
                icon: const Icon(Icons.save_alt),
                label: Text(app.t('disc_save')),
              ),
            ),
        ]),
      ),
    );
  }
}
