import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/engine_api.dart';
import '../../core/image_prep.dart';
import '../../state/app_state.dart';
import '../screens/chart_result.dart';
import '../screens/knowledge_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/signal_details.dart';
import '../screens/signal_log_screen.dart';
import '../screens/training_screen.dart';
import '../theme.dart';

/// The compact floating panel: current recommendation, status and controls.
/// BUY / SELL / WAIT tiles *display* the recommendation and open its details;
/// they never place an order.
enum PanelDestination { library, training, log, settings }

Widget screenFor(PanelDestination d) => switch (d) {
      PanelDestination.library => const KnowledgeScreen(),
      PanelDestination.training => const TrainingScreen(),
      PanelDestination.log => const SignalLogScreen(),
      PanelDestination.settings => const SettingsScreen(),
    };

class FloatingPanel extends StatelessWidget {
  const FloatingPanel({super.key, this.onNavigate, this.pickImage = pickChartImage});

  /// When set (tablet shell), navigation selects a pane instead of pushing a route.
  final void Function(PanelDestination)? onNavigate;
  final FilePickFn pickImage;

  Future<void> _go(BuildContext context, PanelDestination d) async {
    if (onNavigate != null) return onNavigate!(d);
    final app = AppScope.read(context);
    await app.window.setExpanded(true);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screenFor(d)));
    await app.window.setExpanded(false);
  }

  Future<void> _analyzeImage(BuildContext context) async {
    final app = AppScope.read(context);
    var img = await pickImage();
    if (img == null || !context.mounted) return;
    CropFrac? crop;
    if (app.askCrop case final ask?) {
      final d = await ask(img);
      if (d == null || !context.mounted) return; // cancelled
      img = d.image;
      crop = d.crop;
    }
    final chosen = img;
    Json? result;
    final ok = await runWithFeedback(context, () async => result = await app.analyzeChart(chosen, crop: crop));
    if (ok && result != null && context.mounted) await showChartResult(context, result!);
  }

  Future<void> _captureScreen(BuildContext context) async {
    final app = AppScope.read(context);
    Json? result;
    final ok = await runWithFeedback(context, () async => result = await app.captureScreen());
    if (ok && result != null && context.mounted) await showChartResult(context, result!);
  }

  Future<void> _toggleLive(BuildContext context) async {
    final app = AppScope.read(context);
    final live = app.live!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (app.liveActive) {
      await live.stop();
      return;
    }
    final err = await live.start();
    final noFrame = err == null && await live.crop() == null;
    messenger?.showSnackBar(SnackBar(content: Text(app.t(err ?? (noFrame ? 'live_started_no_frame' : 'live_started')))));
  }

  Future<void> _toggleOverlay(BuildContext context) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await app.toggleOverlay();
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(app.t('overlay_permission_denied'))));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                _Header(app: app),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    children: [
                      for (final n in app.notices)
                        Container(
                          key: Key('notice_${n['code']}'),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              border: Border.all(color: SignalColors.sell), borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            app.t('notice_${n['code']}').replaceAll('{kept_as}', '${n['kept_as'] ?? ''}'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      _SignalTiles(app: app, onOpen: () => showSignalDetails(context)),
                      const SizedBox(height: 8),
                      _Metrics(app: app),
                      const SizedBox(height: 8),
                      _StatusLine(app: app),
                      const SizedBox(height: 10),
                      _Controls(app: app),
                      const SizedBox(height: 6),
                      if (app.live != null) ...[
                        FilledButton.tonalIcon(
                          key: const Key('btn_live'),
                          onPressed: app.connected ? () => _toggleLive(context) : null,
                          icon: Icon(app.liveActive ? Icons.stop_circle_outlined : Icons.center_focus_strong),
                          label: Text(app.t(app.liveActive ? 'live_stop' : 'live_start'), overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('btn_analyze_image'),
                            onPressed: app.connected && !app.busy ? () => _analyzeImage(context) : null,
                            icon: const Icon(Icons.image_search),
                            label: Text(app.t('analyze_image'), overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        if (app.canCaptureScreen) ...[
                          const SizedBox(width: 6),
                          IconButton.outlined(
                            key: const Key('btn_capture'),
                            tooltip: app.t('capture_screen'),
                            onPressed: app.connected && !app.busy ? () => _captureScreen(context) : null,
                            icon: const Icon(Icons.screenshot_monitor_outlined),
                          ),
                        ],
                        if (app.overlay.supported && app.live == null) ...[ // with live analysis, its button replaces this one
                          const SizedBox(width: 6),
                          IconButton.outlined(
                            key: const Key('btn_overlay'),
                            tooltip: app.t(app.overlayActive ? 'overlay_hide' : 'overlay_show'),
                            isSelected: app.overlayActive,
                            onPressed: app.connected ? () => _toggleOverlay(context) : null,
                            icon: const Icon(Icons.picture_in_picture_alt_outlined),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (app.has('knowledge'))
                            _NavButton(
                                key: const Key('nav_library'),
                                icon: Icons.menu_book_outlined,
                                label: app.t('library'),
                                onTap: app.connected ? () => _go(context, PanelDestination.library) : null),
                          _NavButton(
                              key: const Key('nav_training'),
                              icon: Icons.school_outlined,
                              label: app.t('training'),
                              onTap: app.connected ? () => _go(context, PanelDestination.training) : null),
                          _NavButton(
                              key: const Key('nav_log'),
                              icon: Icons.receipt_long_outlined,
                              label: app.t('log'),
                              onTap: app.connected ? () => _go(context, PanelDestination.log) : null),
                          _NavButton(
                              key: const Key('nav_settings'),
                              icon: Icons.settings_outlined,
                              label: app.t('settings'),
                              onTap: app.connected ? () => _go(context, PanelDestination.settings) : null),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(app.t('manual_only'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = switch (app.state) {
      'analyzing' => SignalColors.buy,
      'running_no_engine' => SignalColors.wait,
      'halted' => SignalColors.sell,
      'offline' => scheme.outline,
      _ => scheme.outline,
    };
    final row = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: scheme.surfaceContainerHighest,
      child: Row(children: [
        Icon(Icons.circle, size: 10, color: dotColor, key: const Key('status_dot')),
        const SizedBox(width: 8),
        Expanded(
          child: Text(app.t('app_title'),
              overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (app.window.isDesktop) ...[
          IconButton(
              tooltip: 'Minimize',
              iconSize: 18,
              icon: const Icon(Icons.remove),
              onPressed: app.window.minimize),
          IconButton(
              tooltip: app.t('close'), iconSize: 18, icon: const Icon(Icons.close), onPressed: app.window.close),
        ],
      ]),
    );
    // On desktop the header is the drag handle of the frameless window.
    return app.window.isDesktop ? DragToMoveArea(child: row) : row;
  }
}

class _SignalTiles extends StatelessWidget {
  const _SignalTiles({required this.app, required this.onOpen});
  final AppState app;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final current = app.signal;
    Widget tile(String sig, String label, Color color, IconData icon) {
      final active = current == sig;
      return Expanded(
        child: Semantics(
          button: true,
          selected: active,
          label: label,
          child: Material(
            key: Key('tile_$sig'),
            color: active ? color : color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(children: [
                  Icon(icon, color: active ? Colors.white : color),
                  const SizedBox(height: 4),
                  Text(label,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: active ? Colors.white : color, fontSize: 13)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return Column(children: [
      Row(children: [
        tile('BUY', app.t('buy'), SignalColors.buy, Icons.trending_up),
        const SizedBox(width: 8),
        tile('SELL', app.t('sell'), SignalColors.sell, Icons.trending_down),
      ]),
      const SizedBox(height: 8),
      Row(children: [tile('WAIT', app.t('wait'), SignalColors.wait, Icons.hourglass_empty)]),
    ]);
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final rec = app.recommendation;
    final conf = rec['confidence'] as num?;
    final calibrated = rec['confidence_calibrated'] == true;
    final dur = rec['duration_sec'] as int?;
    final tf = (app.status['session'] as Map?)?['timeframe_sec'] ?? app.settings['candle_timeframe_sec'];
    final s = app.t('seconds');
    Widget cell(String label, String value, {String? sub, Key? key}) => Expanded(
          child: Column(children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall, textAlign: TextAlign.center),
            Text(value, key: key, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (sub != null) Text(sub, style: const TextStyle(fontSize: 10)),
          ]),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          cell(app.t('confidence'), conf == null ? '—' : '${(conf * 100).round()}%',
              sub: conf == null || calibrated ? null : app.t('uncalibrated'), key: const Key('confidence_value')),
          cell(app.t('duration'), dur == null ? '—' : '$dur$s', key: const Key('duration_value')),
          cell(app.t('timeframe'), tf == null ? '—' : '$tf$s', key: const Key('timeframe_value')),
        ]),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    if (!app.connected) {
      return Column(children: [
        Text(app.t('state_offline'), key: const Key('status_text'), style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(app.t('offline_help'), style: const TextStyle(fontSize: 11), textAlign: TextAlign.center),
        TextButton(onPressed: app.refresh, child: Text(app.t('retry'))),
      ]);
    }
    final reason = app.recommendation['reason_code'] as String?;
    final watch = app.screenWatch;
    final latest = (watch?['latest'] as Map?)?.cast<String, dynamic>();
    final summary = (latest?['summary'] as Map?)?.cast<String, dynamic>();
    return Column(children: [
      Text(app.t('state_${app.state}'), key: const Key('status_text'),
          textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
      if (reason != null)
        Text(app.t('reason_$reason'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
      if (summary != null)
        Text(
          '${app.t('last_reading')}: ${summary['candles']} · ${app.t('data_quality')} '
          '${(((latest!['data_quality'] as num?) ?? 0) * 100).round()}%',
          key: const Key('watch_line'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
        ),
      if (latest?['technical'] is Map && (latest!['technical'] as Map)['available'] == true)
        Builder(builder: (_) {
          final t = (latest['technical'] as Map).cast<String, dynamic>();
          final dir = ((t['trend'] as Map?)?['direction']) ?? 'sideways';
          return Text(
            '${app.t('trend')}: ${app.t('trend_dir_$dir')} · ${app.t('mc_${t['market_condition']}')} · '
            '↑${(t['supporting_bullish'] as List).length} ↓${(t['supporting_bearish'] as List).length}',
            key: const Key('watch_technical'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          );
        }),
      if (watch?['error'] != null)
        Text('${watch!['error']}', key: const Key('watch_error'),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: SignalColors.sell)),
    ]);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final canAct = app.connected && !app.busy;
    return Column(children: [
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('btn_start'),
            onPressed: canAct && !app.running ? () => runWithFeedback(context, app.startAnalysis) : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(app.t('start')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('btn_stop'),
            onPressed: canAct && app.running ? () => runWithFeedback(context, app.stopAnalysis) : null,
            icon: const Icon(Icons.stop),
            label: Text(app.t('stop')),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const Key('btn_emergency'),
          style: FilledButton.styleFrom(backgroundColor: SignalColors.sell, foregroundColor: Colors.white),
          // always enabled while connected: the kill switch must never be blocked
          onPressed: app.connected ? () => runWithFeedback(context, app.emergencyStop) : null,
          icon: const Icon(Icons.power_settings_new),
          label: Text(app.t('emergency_stop')),
        ),
      ),
    ]);
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Opacity(
          opacity: onTap == null ? 0.4 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              Icon(icon),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      ),
    );
  }
}
