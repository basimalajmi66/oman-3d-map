import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../engine/strategy/from_text.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'paper_trading_screen.dart';
import 'quick_start_screen.dart';
import 'knowledge_screen.dart' show FilePickFn;

Future<UploadFile?> pickCsv() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['csv', 'txt']);
  if (f == null) return null;
  return UploadFile(name: f.name, length: await f.length() ?? 0, openRead: f.readAsByteStream);
}

String _pct(num? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';
String _num(num? v, [int d = 3]) => v == null ? '—' : v.toStringAsFixed(d);
String _gate(AppState app, String r) => hasString('g_$r') ? app.t('g_$r') : r;

/// Training mode: strategies (cards, backtests, approval gate, comparison) and historical data.
class TrainingScreen extends StatelessWidget {
  const TrainingScreen({super.key, this.pickCsvFn = pickCsv});
  final FilePickFn pickCsvFn;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(app.t('training_title')),
          actions: [
            if (app.paper != null)
              IconButton(
                key: const Key('open_paper'),
                tooltip: app.t('paper_title'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PaperTradingScreen())),
                icon: const Icon(Icons.smart_toy_outlined),
              ),
            TextButton.icon(
              key: const Key('open_quick_start'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickStartScreen())),
              icon: const Icon(Icons.rocket_launch_outlined),
              label: Text(app.t('qs_title')),
            ),
          ],
          bottom: TabBar(tabs: [Tab(text: app.t('strategies_tab')), Tab(text: app.t('datasets_tab'))]),
        ),
        body: TabBarView(children: [const _StrategiesTab(), _DatasetsTab(pickCsvFn: pickCsvFn)]),
      ),
    );
  }
}

/// Create a strategy, test it right away on real prices of the timeframe in use, and open its page (results and
/// the approve button). Used by "new strategy" (own words) and by the library (approved rules).
Future<void> createTestAndOpen(BuildContext context, AppState app, String name, Json definition) async {
  Json? s;
  final ok = await runWithFeedback(context, () async => s = await app.engine.createStrategy(name, definition));
  if (!ok || s == null || !context.mounted) return;
  final id = s!['id'] as int;
  final tf = app.settings['candle_timeframe_sec'];
  final data = [for (final d in await app.engine.listDatasets()) if (d['timeframe_sec'] == tf && d['is_synthetic'] != 1) d]
    ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
  if (!context.mounted) return;
  if (data.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t('strategy_no_data_for_tf'))));
  } else {
    await runWithFeedback(context, () => app.engine.backtest(id, data.first['id'] as int));
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StrategyPage(strategyId: id)));
}

// ---------------------------------------------------------------- strategies list
class _StrategiesTab extends StatefulWidget {
  const _StrategiesTab();
  @override
  State<_StrategiesTab> createState() => _StrategiesTabState();
}

class _StrategiesTabState extends State<_StrategiesTab> {
  List<Json> _items = [];
  final Set<int> _selected = {};
  bool _loading = true;

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final s = await app.engine.listStrategies();
      if (mounted) setState(() => _items = s);
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final created = await showDialog<Json>(context: context, builder: (_) => _StrategyBuilder(app: app));
    if (created == null || !mounted) return;
    await createTestAndOpen(context, app, created['name'] as String, created['definition'] as Json);
    await _reload();
  }

  Future<void> _compare() async {
    final datasets = await app.engine.listDatasets();
    if (!mounted || datasets.isEmpty) return;
    final did = await _pickDataset(context, app, datasets);
    if (did == null || !mounted) return;
    List<Json> rows = [];
    final ok = await runWithFeedback(context, () async => rows = await app.engine.compareStrategies(_selected.toList(), did));
    if (!ok || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(app.t('compare')),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              key: const Key('compare_table'),
              columns: [
                DataColumn(label: Text(app.t('strategies_tab'))),
                DataColumn(label: Text(app.t('trades'))),
                DataColumn(label: Text(app.t('win_rate'))),
                DataColumn(label: Text(app.t('expectancy'))),
                DataColumn(label: Text(app.t('profit_factor'))),
                DataColumn(label: Text(app.t('qualifies'))),
              ],
              rows: rows
                  .map((r) => DataRow(cells: [
                        DataCell(Text('${r['name']}')),
                        DataCell(Text('${r['trades']}')),
                        DataCell(Text(_pct(r['win_rate'] as num?))),
                        DataCell(Text(_num(r['expectancy_per_trade'] as num?))),
                        DataCell(Text(_num(r['profit_factor'] as num?, 2))),
                        DataCell(Icon(r['qualifies'] == true ? Icons.check_circle : Icons.cancel,
                            color: r['qualifies'] == true ? SignalColors.buy : SignalColors.sell)),
                      ]))
                  .toList(),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('close')))],
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new_strategy'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(app.t('new_strategy')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(child: Text(app.t('win_rate_alone_note'), style: const TextStyle(fontSize: 11))),
                  OutlinedButton.icon(
                    key: const Key('btn_compare'),
                    onPressed: _selected.length >= 2 ? _compare : null,
                    icon: const Icon(Icons.compare_arrows),
                    label: Text('${app.t('compare')} (${_selected.length})'),
                  ),
                ]),
              ),
              Expanded(
                child: _items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(app.t('no_strategies'), key: const Key('no_strategies')),
                            const SizedBox(height: 16),
                            Text(app.t('qs_empty_hint'), textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              key: const Key('quick_start_big'),
                              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18)),
                              onPressed: () async {
                                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickStartScreen()));
                                await _reload();
                              },
                              icon: const Icon(Icons.rocket_launch_outlined),
                              label: Text(app.t('qs_title')),
                            ),
                          ]),
                        ),
                      )
                    : ListView(
                        children: _items.map((s) {
                          final id = s['id'] as int;
                          final oos = ((s['latest_backtest'] as Map?)?['out_of_sample'] as Map?)?.cast<String, dynamic>();
                          return ListTile(
                            key: Key('strategy_$id'),
                            leading: Checkbox(
                              key: Key('select_$id'),
                              value: _selected.contains(id),
                              onChanged: (v) => setState(() => v == true ? _selected.add(id) : _selected.remove(id)),
                            ),
                            title: Text('${s['name']}'),
                            subtitle: Text('${app.t('st_${s['status']}')} · ${app.t('version')} ${s['version']}'
                                '${oos != null ? ' · ${app.t('out_of_sample')}: ${oos['trades']} · ${_num(oos['expectancy_per_trade'] as num?)}' : ''}'),
                            onTap: () async {
                              await Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => StrategyPage(strategyId: id)));
                              await _reload();
                            },
                          );
                        }).toList(),
                      ),
              ),
            ]),
    );
  }
}

Future<int?> _pickDataset(BuildContext context, AppState app, List<Json> datasets) => showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(app.t('dataset')),
        children: datasets
            .map((d) => SimpleDialogOption(
                  key: Key('pick_dataset_${d['id']}'),
                  onPressed: () => Navigator.pop(ctx, d['id'] as int),
                  child: Text('${d['name']} · ${d['rows']} ${app.t('rows')}'
                      '${d['is_synthetic'] == 1 ? ' · ${app.t('synthetic_label')}' : ''}'),
                ))
            .toList(),
      ),
    );

// ---------------------------------------------------------------- strategy page
class StrategyPage extends StatefulWidget {
  const StrategyPage({super.key, required this.strategyId});
  final int strategyId;
  @override
  State<StrategyPage> createState() => _StrategyPageState();
}

class _StrategyPageState extends State<StrategyPage> {
  Json? _s;
  Json? _lastRun;
  List<String> _refusal = [];

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final s = await app.engine.getStrategy(widget.strategyId);
      if (mounted) setState(() => _s = s);
    });
  }

  Future<void> _backtest() async {
    final datasets = await app.engine.listDatasets();
    if (!mounted) return;
    if (datasets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t('no_datasets'))));
      return;
    }
    final did = await _pickDataset(context, app, datasets);
    if (did == null || !mounted) return;
    await runWithFeedback(context, () async {
      final r = await app.engine.backtest(widget.strategyId, did);
      if (mounted) setState(() => _lastRun = r);
    });
    await _reload();
  }

  Future<void> _approve() async {
    try {
      await app.engine.approveStrategy(widget.strategyId);
      if (mounted) setState(() => _refusal = []);
    } on EngineException catch (e) {
      if (mounted) setState(() => _refusal = e.reasons.isEmpty ? [e.message] : e.reasons);
    }
    await _reload();
  }

  Widget _metrics(String title, Json m, {Key? key}) {
    final ci = (m['win_rate_ci95'] as List?)?.cast<num>();
    final sig = m['significant_edge'] == true;
    return Card(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('${app.t('trades')}: ${m['trades']}  ·  ${app.t('win_rate')}: ${_pct(m['win_rate'] as num?)}'
              '${ci != null ? '  (${app.t('ci95')} ${_pct(ci[0])}–${_pct(ci[1])})' : ''}'),
          Text('${app.t('breakeven')}: ${_pct(m['breakeven_win_rate'] as num?)}  ·  '
              '${app.t('expectancy')}: ${_num(m['expectancy_per_trade'] as num?)}'),
          Text('${app.t('profit_factor')}: ${_num(m['profit_factor'] as num?, 2)}  ·  '
              '${app.t('max_drawdown')}: ${_num(m['max_drawdown_units'] as num?, 2)}'),
          Text(app.t(sig ? 'significant_edge' : 'no_significant_edge'),
              style: TextStyle(color: sig ? SignalColors.buy : SignalColors.wait, fontWeight: FontWeight.w600)),
          if (m['by_condition'] is Map) ...[
            const SizedBox(height: 4),
            Text(app.t('by_condition'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ...(m['by_condition'] as Map).entries.map((e) => Text(
                '• ${app.t('mc_${e.key}')}: ${(e.value as Map)['trades']} · ${_num((e.value as Map)['expectancy_per_trade'] as num?)}',
                style: const TextStyle(fontSize: 12))),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = _s;
    if (s == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final readable = (s['readable_ar'] as Map?)?.cast<String, dynamic>() ?? const {};
    final readableEn = (s['readable'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<String> conds(String side) =>
        ((app.lang == 'ar' ? readable[side] : readableEn[side]) as List? ?? const []).cast<String>();
    final untestable = ((s['definition'] as Map?)?['untestable'] as List? ?? const []).cast<String>();
    final latest = (s['latest_backtest'] as Map?)?.cast<String, dynamic>();
    final run = _lastRun;
    return Scaffold(
      appBar: AppBar(title: Text('${s['name']}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, children: [
          Chip(key: const Key('strategy_status'), label: Text(app.t('st_${s['status']}'))),
          Chip(label: Text('${app.t('version')} ${s['version']}')),
        ]),
        if ((s['description'] as String? ?? '').isNotEmpty) Text('${s['description']}'),
        for (final side in ['long', 'short', 'veto'])
          if (conds(side).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(app.t('${side}_conditions'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ...conds(side).map((c) => Text('• $c')),
          ],
        if (untestable.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(app.t('untestable_rules'), key: const Key('untestable'),
              style: const TextStyle(fontWeight: FontWeight.bold, color: SignalColors.wait)),
          ...untestable.map((t) => Text('• $t', style: const TextStyle(fontSize: 12))),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(key: const Key('btn_backtest'), onPressed: _backtest, icon: const Icon(Icons.science_outlined),
              label: Text(app.t('run_backtest'))),
          OutlinedButton.icon(key: const Key('btn_approve_strategy'), onPressed: _approve,
              icon: const Icon(Icons.verified_outlined), label: Text(app.t('approve_strategy'))),
          TextButton(onPressed: () async {
            await runWithFeedback(context, () => app.engine.retireStrategy(widget.strategyId));
            await _reload();
          }, child: Text(app.t('retire'))),
        ]),
        if (_refusal.isNotEmpty)
          Container(
            key: const Key('approval_refused'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(border: Border.all(color: SignalColors.sell), borderRadius: BorderRadius.circular(6)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.t('approval_refused'), style: const TextStyle(fontWeight: FontWeight.bold, color: SignalColors.sell)),
              ..._refusal.map((r) => Text('• ${_gate(app, r)}')),
            ]),
          ),
        if (run != null) ...[
          const SizedBox(height: 12),
          Text(run['qualifies'] == true ? app.t('qualifies') : app.t('not_qualifies'),
              key: const Key('run_qualifies'),
              style: TextStyle(fontWeight: FontWeight.bold, color: run['qualifies'] == true ? SignalColors.buy : SignalColors.wait)),
          if (run['synthetic'] == true) Text(app.t('synthetic_label'), style: const TextStyle(color: SignalColors.wait)),
          ...((run['gate_reasons'] as List?) ?? const []).map((r) => Text('• ${_gate(app, r as String)}', style: const TextStyle(fontSize: 12))),
          _metrics(app.t('in_sample'), (run['in_sample'] as Map).cast<String, dynamic>(), key: const Key('m_in_sample')),
          _metrics(app.t('out_of_sample'), (run['out_of_sample'] as Map).cast<String, dynamic>(), key: const Key('m_out_of_sample')),
        ] else if (latest != null) ...[
          const SizedBox(height: 12),
          Text('${app.t('backtests')}: ${latest['dataset']}'),
          if (latest['out_of_sample'] is Map)
            _metrics(app.t('out_of_sample'), (latest['out_of_sample'] as Map).cast<String, dynamic>()),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- strategy builder
class _StrategyBuilder extends StatefulWidget {
  const _StrategyBuilder({required this.app});
  final AppState app;
  @override
  State<_StrategyBuilder> createState() => _StrategyBuilderState();
}

class _StrategyBuilderState extends State<_StrategyBuilder> {
  final _name = TextEditingController();
  final _duration = TextEditingController(text: '120');
  final _text = TextEditingController();
  List<String> _untestable = [];
  List<String> _used = [];
  bool _converted = false;

  /// The user's own words → conditions (deterministic reader; untestable sentences are listed, never guessed).
  void _convert() {
    final (def, used, untestable) = strategyFromText(_text.text, defaultDuration: int.tryParse(_duration.text) ?? 120);
    setState(() {
      _converted = true;
      _used = used;
      _untestable = untestable;
      _conds['long'] = [for (final c in ((def['long'] as Map)['all'] as List)) (c as Map).cast<String, dynamic>()];
      _conds['short'] = [for (final c in ((def['short'] as Map)['all'] as List)) (c as Map).cast<String, dynamic>()];
      _conds['veto'] = [for (final c in (def['veto'] as List)) (c as Map).cast<String, dynamic>()];
      _duration.text = '${def['duration_sec']}';
      if (_name.text.trim().isEmpty) {
        final t = _text.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        _name.text = t.length > 40 ? '${t.substring(0, 40)}…' : t;
      }
    });
  }
  List<Json> _catalog = [];
  final Map<String, List<Json>> _conds = {'long': [], 'short': [], 'veto': []};

  @override
  void initState() {
    super.initState();
    widget.app.engine.strategyCatalog().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
  }

  String _label(Json c) {
    final spec = _catalog.firstWhere((x) => x['id'] == c['id'], orElse: () => {'en': c['id'], 'ar': c['id']});
    var tpl = '${spec[widget.app.lang]}';
    c.forEach((k, v) => tpl = tpl.replaceAll('{$k}', '$v'));
    ((spec['params'] as Map?) ?? const {}).forEach((k, v) => tpl = tpl.replaceAll('{$k}', '$v'));
    return tpl;
  }

  Future<void> _add(String side) async {
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(widget.app.t('add_condition')),
        children: _catalog
            .map((c) => SimpleDialogOption(
                  key: Key('cond_${c['id']}'),
                  onPressed: () => Navigator.pop(ctx, c['id'] as String),
                  child: Text(_label({'id': c['id']})),
                ))
            .toList(),
      ),
    );
    if (id != null) setState(() => _conds[side]!.add({'id': id}));
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final duration = int.tryParse(_duration.text);
    final valid = _name.text.trim().isNotEmpty && duration != null && (_conds['long']!.isNotEmpty || _conds['short']!.isNotEmpty);
    return AlertDialog(
      title: Text(app.t('new_strategy')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(app.t('strategy_in_words'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            TextField(
              key: const Key('strategy_text'),
              controller: _text,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(border: const OutlineInputBorder(), hintText: app.t('strategy_in_words_hint')),
              onChanged: (_) => setState(() {}),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                key: const Key('strategy_convert'),
                onPressed: _text.text.trim().isEmpty ? null : _convert,
                icon: const Icon(Icons.auto_fix_high),
                label: Text(app.t('strategy_convert')),
              ),
            ),
            if (_converted && _conds['long']!.isEmpty && _conds['short']!.isEmpty)
              Text(app.t('strategy_nothing_testable'), key: const Key('strategy_nothing'),
                  style: const TextStyle(color: SignalColors.wait, fontSize: 12)),
            if (_converted && _used.isNotEmpty)
              Text('${app.t('strategy_understood')}: ${_used.length}', style: const TextStyle(color: SignalColors.buy, fontSize: 12)),
            for (final u in _untestable)
              Text('• ${app.t('strategy_untestable')}: $u', style: const TextStyle(color: SignalColors.wait, fontSize: 12)),
            const Divider(height: 20),
            TextField(key: const Key('strategy_name'), controller: _name, decoration: InputDecoration(labelText: app.t('title')),
                onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            TextField(controller: _duration, keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: app.t('duration_sec')), onChanged: (_) => setState(() {})),
            for (final side in ['long', 'short', 'veto']) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text(app.t('${side}_conditions'), style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(key: Key('add_$side'), icon: const Icon(Icons.add_circle_outline), onPressed: () => _add(side)),
              ]),
              ..._conds[side]!.asMap().entries.map((e) => Row(children: [
                    Expanded(child: Text('• ${_label(e.value)}')),
                    IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _conds[side]!.removeAt(e.key))),
                  ])),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('cancel'))),
        FilledButton(
          key: const Key('strategy_save'),
          onPressed: valid
              ? () => Navigator.pop(context, {
                    'name': _name.text.trim(),
                    'definition': {
                      'long': {'all': _conds['long']},
                      'short': {'all': _conds['short']},
                      'veto': _conds['veto'],
                      'duration_sec': duration,
                      if (_untestable.isNotEmpty) 'untestable': _untestable,
                      if (_used.isNotEmpty) 'translated_rules': _used,
                    },
                  })
              : null,
          child: Text(app.t('save')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- datasets
class _DatasetsTab extends StatefulWidget {
  const _DatasetsTab({required this.pickCsvFn});
  final FilePickFn pickCsvFn;
  @override
  State<_DatasetsTab> createState() => _DatasetsTabState();
}

class _DatasetsTabState extends State<_DatasetsTab> {
  List<Json> _items = [];

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final d = await app.engine.listDatasets();
      if (mounted) setState(() => _items = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          key: const Key('btn_import_csv'),
          icon: const Icon(Icons.upload_file),
          label: Text(app.t('import_csv')),
          onPressed: () async {
            final f = await widget.pickCsvFn();
            if (f == null || !context.mounted) return;
            await runWithFeedback(context, () => app.engine.importDataset(f), successKey: 'saved');
            await _reload();
          },
        ),
        OutlinedButton.icon(
          key: const Key('btn_synthetic'),
          icon: const Icon(Icons.auto_graph),
          label: Text(app.t('synthetic_data')),
          onPressed: () async {
            await runWithFeedback(context, () => app.engine.syntheticDataset(seed: DateTime.now().millisecond));
            await _reload();
          },
        ),
      ]),
      const SizedBox(height: 8),
      if (_items.isEmpty) Text(app.t('no_datasets'), key: const Key('no_datasets')),
      ..._items.map((d) => ListTile(
            key: Key('dataset_${d['id']}'),
            leading: Icon(d['is_synthetic'] == 1 ? Icons.science_outlined : Icons.table_chart_outlined,
                color: d['is_synthetic'] == 1 ? SignalColors.wait : null),
            title: Text('${d['name']}'),
            subtitle: Text('${d['rows']} ${app.t('rows')} · ${d['timeframe_sec']}${app.t('seconds')}'
                '${d['is_synthetic'] == 1 ? ' · ${app.t('synthetic_label')}' : ''}'),
            trailing: IconButton(
              tooltip: app.t('delete'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await runWithFeedback(context, () => app.engine.deleteDataset(d['id'] as int));
                await _reload();
              },
            ),
          )),
    ]);
  }
}
