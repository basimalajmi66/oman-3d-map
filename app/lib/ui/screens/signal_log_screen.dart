import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart' show factorText, hasString;
import '../../state/app_state.dart';
import '../theme.dart';
import 'signal_details.dart';
import 'stats_view.dart';

/// Signal history and the manual trade-result journal. Results are always
/// grouped by account type (simulation / demo / real) and never mixed.
class SignalLogScreen extends StatefulWidget {
  const SignalLogScreen({super.key});
  @override
  State<SignalLogScreen> createState() => _SignalLogScreenState();
}

class _SignalLogScreenState extends State<SignalLogScreen> {
  List<Json> _signals = [], _results = [];
  Json _summary = {};
  bool _loading = true;

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final s = await app.engine.listSignals();
      final r = await app.engine.listResults();
      final sum = await app.engine.summary();
      if (mounted) {
        setState(() {
          _signals = s;
          _results = r;
          _summary = sum;
        });
      }
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _recordFromSignal(Json g) async {
    var account = 'demo', outcome = 'win';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('${app.t('record_result')}: ${g['signal']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              key: const Key('rr_account'),
              segments: [for (final a in ['simulation', 'demo', 'real']) ButtonSegment(value: a, label: Text(app.t(a)))],
              selected: {account},
              onSelectionChanged: (v) => setLocal(() => account = v.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              key: const Key('rr_outcome'),
              segments: [for (final o in ['win', 'loss', 'draw', 'cancelled']) ButtonSegment(value: o, label: Text(app.t(o)))],
              selected: {outcome},
              onSelectionChanged: (v) => setLocal(() => outcome = v.first),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
            FilledButton(key: const Key('rr_save'), onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await runWithFeedback(context, () => app.engine.resultFromSignal(g['id'] as int, accountType: account, outcome: outcome),
        successKey: 'saved');
    await _reload();
  }

  Future<void> _addResult() async {
    final r = await showDialog<Json>(context: context, builder: (_) => _ResultDialog(app: app));
    if (r == null || !mounted) return;
    await runWithFeedback(context, () => app.engine.addResult(r), successKey: 'saved');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(app.t('log')),
          bottom: TabBar(tabs: [Tab(text: app.t('signals_tab')), Tab(text: app.t('results_tab')), Tab(text: app.t('stats_tab'))]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('add_result'),
          onPressed: _addResult,
          icon: const Icon(Icons.add),
          label: Text(app.t('add_result')),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [_signalsTab(app), _resultsTab(app), const StatsView()]),
      ),
    );
  }

  Widget _signalsTab(AppState app) {
    final s = (_summary['signals'] as Map?) ?? const {};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('${app.t('total')}: ${s['total'] ?? 0}', Colors.blueGrey),
          _chip('BUY: ${s['BUY'] ?? 0}', SignalColors.buy),
          _chip('SELL: ${s['SELL'] ?? 0}', SignalColors.sell),
          _chip('WAIT: ${s['WAIT'] ?? 0}', SignalColors.wait),
        ]),
      ),
      Expanded(
        child: _signals.isEmpty
            ? Center(child: Text(app.t('no_signals'), key: const Key('no_signals')))
            : ListView(
                children: _signals
                    .map((g) => ListTile(
                          leading: CircleAvatar(
                            backgroundColor: switch (g['signal']) {
                              'BUY' => SignalColors.buy,
                              'SELL' => SignalColors.sell,
                              _ => SignalColors.wait,
                            },
                            child: Text((g['signal'] as String).substring(0, 1), style: const TextStyle(color: Colors.white)),
                          ),
                          title: Text('${g['signal']} · ${g['asset'] ?? '—'} · ${g['timeframe_sec']}${app.t('seconds')}'),
                          subtitle: Text([
                            fmtDate(g['created_at'] as String?),
                            ?_waitReason(app, g),
                          ].join('\n'), key: Key('signal_sub_${g['id']}')),
                          isThreeLine: _waitReason(app, g) != null,
                          onTap: () => showSignalDetails(context, signal: g),
                          trailing: g['signal'] == 'WAIT'
                              ? null
                              : IconButton(
                                  key: Key('record_${g['id']}'),
                                  tooltip: app.t('record_result'),
                                  icon: const Icon(Icons.flag_outlined),
                                  onPressed: () => _recordFromSignal(g),
                                ),
                        ))
                    .toList(),
              ),
      ),
    ]);
  }

  Widget _resultsTab(AppState app) {
    final by = (_summary['results_by_account'] as Map?) ?? const {};
    return ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: ['simulation', 'demo', 'real'].map((acct) {
          final m = (by[acct] as Map?) ?? const {};
          final rate = m['win_rate'] as num?;
          final n = m['sample_size'] as int? ?? 0;
          return SizedBox(
            width: 200,
            child: Card(
              key: Key('acct_$acct'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(app.t(acct), style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('${app.t('total')}: ${m['total'] ?? 0}'),
                  Text('${app.t('win')}: ${m['wins'] ?? 0} · ${app.t('loss')}: ${m['losses'] ?? 0}'),
                  Text('${app.t('win_rate')}: ${rate == null ? '—' : '${(rate * 100).toStringAsFixed(1)}%'} (${app.t('sample')} $n)'),
                  if (n > 0 && n < 30) Text(app.t('small_sample'), style: const TextStyle(fontSize: 11, color: SignalColors.wait)),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
      const SizedBox(height: 12),
      if (_results.isEmpty) Center(child: Text(app.t('no_trades'))),
      ..._results.map((r) => Card(
            child: ListTile(
              title: Text('${r['signal_type']} · ${r['asset']} · ${app.t(r['outcome'] as String)}'),
              subtitle: Text('${app.t(r['account_type'] as String)} · ${r['duration_sec']}${app.t('seconds')} · '
                  '${fmtDate(r['signal_time'] as String?)}${r['notes'] != null ? '\n${r['notes']}' : ''}'),
              trailing: IconButton(
                tooltip: app.t('delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await runWithFeedback(context, () => app.engine.deleteResult(r['id'] as int));
                  await _reload();
                },
              ),
            ),
          )),
      const SizedBox(height: 72),
    ]);
  }

  Widget _chip(String text, Color c) =>
      Chip(label: Text(text), backgroundColor: c.withValues(alpha: 0.15), side: BorderSide(color: c));
}

class _ResultDialog extends StatefulWidget {
  const _ResultDialog({required this.app});
  final AppState app;
  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  String _account = 'demo', _direction = 'BUY', _outcome = 'win';
  final _asset = TextEditingController(), _duration = TextEditingController(text: '120');
  final _notes = TextEditingController();

  Widget _dd(String label, String value, List<String> opts, ValueChanged<String> on, {bool translate = true}) => Row(children: [
        Expanded(child: Text(label)),
        DropdownButton<String>(
          value: value,
          items: opts.map((o) => DropdownMenuItem(value: o, child: Text(translate ? widget.app.t(o) : o))).toList(),
          onChanged: (v) => setState(() => on(v!)),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final duration = int.tryParse(_duration.text);
    final valid = _asset.text.trim().isNotEmpty && duration != null && duration > 0;
    return AlertDialog(
      title: Text(app.t('add_result')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _dd(app.t('account_type'), _account, const ['simulation', 'demo', 'real'], (v) => _account = v),
            _dd(app.t('direction'), _direction, const ['BUY', 'SELL'], (v) => _direction = v, translate: false),
            _dd(app.t('outcome'), _outcome, const ['win', 'loss', 'draw', 'cancelled'], (v) => _outcome = v),
            TextField(key: const Key('result_asset'), controller: _asset, decoration: InputDecoration(labelText: app.t('asset')),
                onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            TextField(
                controller: _duration,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: '${app.t('duration')} (${app.t('seconds')})'),
                onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            TextField(controller: _notes, maxLines: 3, decoration: InputDecoration(labelText: app.t('notes'))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('cancel'))),
        FilledButton(
          key: const Key('result_save'),
          onPressed: valid
              ? () => Navigator.pop(context, <String, dynamic>{
                    'account_type': _account,
                    'asset': _asset.text.trim(),
                    'timeframe_sec': app.settings['candle_timeframe_sec'] ?? 30,
                    'signal_type': _direction,
                    'signal_time': DateTime.now().toUtc().toIso8601String(),
                    'duration_sec': duration,
                    'outcome': _outcome,
                    'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                  })
              : null,
          child: Text(app.t('save')),
        ),
      ],
    );
  }
}

/// Why a WAIT was given (its reason code), in the user's language — shown right in the list.
String? _waitReason(AppState app, Map g) {
  final rs = g['reasons'];
  // a pattern signal: which patterns
  if (g['signal'] != 'WAIT' && rs is List && rs.isNotEmpty && '${rs.first}'.startsWith('setup: ')) {
    return '${app.t('pattern_signal_tag')}: ${[for (final r in rs) factorText(app.lang, '$r').replaceFirst('${app.t('ind_setup')} — ', '')].join('، ')}';
  }
  if (g['signal'] != 'WAIT') return null;
  final code = rs is List && rs.isNotEmpty ? '${rs.first}' : null;
  if (code == null || !hasString('reason_$code')) return null;
  return app.t('reason_$code');
}
