import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../data/market_data.dart';
import '../../data/paper_trading.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Automatic PAPER trading: virtual trades on real prices, recorded as simulation results. Never real money.
class PaperTradingScreen extends StatefulWidget {
  const PaperTradingScreen({super.key});
  @override
  State<PaperTradingScreen> createState() => _PaperTradingScreenState();
}

class _PaperTradingScreenState extends State<PaperTradingScreen> {
  bool _busy = false;
  bool _bgOn = false;
  AppState get app => AppScope.read(context);
  PaperTrader get paper => app.paper!;

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refreshBackground();
    // the background service writes the session files: show its progress while this screen is open
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _refreshBackground());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refreshBackground() async {
    final on = await AppScope.read(context).background?.isRunning() ?? false;
    if (mounted) setState(() => _bgOn = on);
  }

  Future<void> _toggleBackground(bool on) async {
    final bg = app.background!;
    if (on) {
      if (app.settings['external_data_sources_allowed'] != true) {
        await app.updateSettings({'external_data_sources_allowed': true}); // turning it on = consent to download prices
      }
      final err = await bg.start(app.lang);
      if (err != null) _snack(app.t(err));
    } else {
      await bg.stop();
    }
    await _refreshBackground();
  }

  Future<void> _new() async {
    final strategies = [for (final s in await app.engine.listStrategies()) if (s['definition'] != null) s];
    if (!mounted) return;
    final r = await showDialog<(MarketAsset, double, List<int>)>(
        context: context, builder: (_) => _NewSessionDialog(app: app, strategies: strategies));
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (app.settings['external_data_sources_allowed'] != true) {
        await app.updateSettings({'external_data_sources_allowed': true}); // the user ticked the consent box
      }
      await paper.start(app.engine, r.$1, app.settings['candle_timeframe_sec'] as int? ?? 30, r.$2, r.$3);
    } on MarketDataException catch (e) {
      _snack(e.message);
    } on EngineException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(PaperSession s) async {
    setState(() => _busy = true);
    try {
      await paper.update(app.engine, s);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  String _pct(Object? v) => v == null ? '—' : '${((v as num) * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sessions = paper.sessions();
    return Scaffold(
      appBar: AppBar(title: Text(app.t('paper_title'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('paper_new'),
        onPressed: _busy ? null : _new,
        icon: const Icon(Icons.play_arrow),
        label: Text(app.t('paper_new')),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(app.t('paper_intro'), key: const Key('paper_intro'))),
        ),
        if (app.background != null)
          Card(
            child: Column(children: [
              SwitchListTile(
                key: const Key('bg_switch'),
                secondary: const Icon(Icons.notifications_active_outlined),
                title: Text(app.t('bg_title')),
                subtitle: Text(app.t('bg_sub')),
                value: _bgOn,
                onChanged: _toggleBackground,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(app.t('bg_fresh_note'), key: const Key('bg_note'), style: Theme.of(context).textTheme.bodySmall),
              ),
            ]),
          ),
        if (_busy) const LinearProgressIndicator(),
        if (sessions.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(app.t('paper_none')))),
        for (final s in sessions) _sessionCard(app, s),
      ]),
    );
  }

  Widget _sessionCard(AppState app, PaperSession s) {
    final asset = marketAssets.where((a) => a.symbol == s.asset).firstOrNull;
    final started = DateTime.fromMillisecondsSinceEpoch(s.startedAt * 1000).toLocal();
    final rows = s.summary();
    final breakeven = 1 / (1 + s.payout);
    return Card(
      key: Key('paper_session_${s.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(s.status == 'running' ? Icons.play_circle : Icons.stop_circle,
                color: s.status == 'running' ? SignalColors.buy : SignalColors.wait),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${app.lang == 'ar' ? asset?.ar ?? s.asset : asset?.en ?? s.asset} · ${s.timeframeSec}s · ${app.t('payout')} ${(s.payout * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
          Text('${app.t('paper_started')}: ${started.toString().substring(0, 16)}  ·  ${app.t('paper_last_update')}: ${s.lastUpdate?.substring(0, 16).replaceFirst('T', ' ') ?? '—'} UTC'),
          if (s.waiting > 0) Text(app.t('paper_waiting').replaceAll('{n}', '${s.waiting}')),
          if (s.lastError != null) Text('${app.t('error')}: ${s.lastError}', style: const TextStyle(color: SignalColors.sell)),
          const SizedBox(height: 6),
          if (rows.isEmpty) Text(app.t('paper_no_trades_yet')),
          for (final r in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r['name']}'),
              subtitle: Text('${app.t('paper_trades')}: ${r['trades']} · ${app.t('qs_win_rate')}: ${_pct(r['win_rate'])}'
                  '${r['ci95'] is List ? ' (${_pct((r['ci95'] as List)[0])}–${_pct((r['ci95'] as List)[1])})' : ''}'
                  ' · ${app.t('qs_breakeven')}: ${_pct(breakeven)}'),
              trailing: Text('${(r['net'] as double) >= 0 ? '+' : ''}${(r['net'] as double).toStringAsFixed(2)}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: (r['net'] as double) >= 0 ? SignalColors.buy : SignalColors.sell)),
            ),
          Text(app.t('paper_net_hint'), style: Theme.of(context).textTheme.bodySmall),
          Wrap(spacing: 8, children: [
            if (s.status == 'running' && !_bgOn) // with background mode on, the service updates (never two at once)
              TextButton.icon(key: Key('paper_update_${s.id}'), onPressed: _busy ? null : () => _update(s), icon: const Icon(Icons.refresh), label: Text(app.t('paper_update'))),
            if (s.status == 'running')
              TextButton.icon(key: Key('paper_stop_${s.id}'), onPressed: () => setState(() => paper.stop(s.id)), icon: const Icon(Icons.stop), label: Text(app.t('stop'))),
            TextButton.icon(key: Key('paper_delete_${s.id}'), onPressed: () => setState(() => paper.delete(s.id)), icon: const Icon(Icons.delete_outline), label: Text(app.t('delete'))),
          ]),
        ]),
      ),
    );
  }
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({required this.app, required this.strategies});
  final AppState app;
  final List<Json> strategies;
  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  MarketAsset _asset = marketAssets.first;
  double _payout = 0.85;
  late final Set<int> _chosen = {for (final s in widget.strategies) if (s['status'] == 'approved') s['id'] as int};
  late bool _consent = widget.app.settings['external_data_sources_allowed'] == true;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AlertDialog(
      title: Text(app.t('paper_new')),
      content: SizedBox(
        width: 460,
        child: ListView(shrinkWrap: true, children: [
          DropdownButtonFormField<MarketAsset>(
            key: const Key('paper_asset'),
            initialValue: _asset,
            decoration: InputDecoration(labelText: app.t('qs_asset'), helperText: app.t('paper_otc_hint'), helperMaxLines: 3),
            items: [for (final a in marketAssets) DropdownMenuItem(value: a, child: Text(app.lang == 'ar' ? a.ar : a.en))],
            onChanged: (a) => setState(() => _asset = a!),
          ),
          DropdownButtonFormField<double>(
            initialValue: _payout,
            decoration: InputDecoration(labelText: app.t('qs_payout')),
            items: [for (final p in const [0.70, 0.75, 0.80, 0.82, 0.85, 0.88, 0.90, 0.92]) DropdownMenuItem(value: p, child: Text('${(p * 100).round()}%'))],
            onChanged: (p) => setState(() => _payout = p!),
          ),
          const SizedBox(height: 8),
          Text(app.t('paper_strategies'), style: const TextStyle(fontWeight: FontWeight.bold)),
          if (widget.strategies.isEmpty) Text(app.t('no_strategies')),
          for (final s in widget.strategies)
            CheckboxListTile(
              key: Key('paper_pick_${s['id']}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _chosen.contains(s['id']),
              onChanged: (v) => setState(() => v == true ? _chosen.add(s['id'] as int) : _chosen.remove(s['id'])),
              title: Text('${s['name']}'),
              subtitle: Text(s['status'] == 'approved' ? app.t('approved') : app.t('st_${s['status']}')),
            ),
          CheckboxListTile(
            key: const Key('paper_consent'),
            contentPadding: EdgeInsets.zero,
            value: _consent,
            onChanged: (v) => setState(() => _consent = v ?? false),
            title: Text(app.t('qs_consent')),
            subtitle: Text(app.t('qs_consent_hint')),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('cancel'))),
        FilledButton(
          key: const Key('paper_start'),
          onPressed: _consent && _chosen.isNotEmpty ? () => Navigator.pop(context, (_asset, _payout, _chosen.toList())) : null,
          child: Text(app.t('qs_start')),
        ),
      ],
    );
  }
}
