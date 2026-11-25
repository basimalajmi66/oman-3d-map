import 'dart:async';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../platform/android_overlay.dart' show registerPort, sendToApp, overlayDataPort;
import '../theme.dart';

/// UI of the Android floating window. Runs in its own Flutter engine and
/// receives state from the main app through [FlutterOverlayWindow.shareData].
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key, this.updates, this.onClose, this.send, this.ticker, this.now});

  /// How often the countdowns refresh (null = never; the real window passes one second).
  final Duration? ticker;

  /// Clock (injectable for tests).
  final DateTime Function()? now;

  /// Payload stream; defaults to the overlay channel. Injectable for tests.
  final Stream<dynamic>? updates;
  final VoidCallback? onClose;

  /// Commands to the main app (live analysis); defaults to the overlay channel.
  final void Function(Json)? send;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.dark),
    home: Material(
      color: Colors.transparent,
      child: OverlayCard(
        updates: updates ?? _windowUpdates(),
        onClose: onClose ?? () => FlutterOverlayWindow.closeOverlay(),
        send: send ?? sendToApp,
        ticker: ticker,
        now: now,
      ),
    ),
  );
}

/// What the app sends to the window: the direct port (reliable) merged with the plugin channel (fallback).
Stream<dynamic> _windowUpdates() {
  final port = registerPort(overlayDataPort);
  final out = StreamController<dynamic>.broadcast();
  port.listen(out.add);
  FlutterOverlayWindow.overlayListener.listen(out.add);
  return out.stream;
}

class OverlayCard extends StatefulWidget {
  const OverlayCard({super.key, required this.updates, required this.onClose, this.send, this.ticker, this.now});
  final Stream<dynamic> updates;
  final VoidCallback onClose;
  final void Function(Json)? send;
  final Duration? ticker;
  final DateTime Function()? now;

  @override
  State<OverlayCard> createState() => _OverlayCardState();
}

class _OverlayCardState extends State<OverlayCard> {
  Json _data = const {'lang': 'ar', 'state': 'idle', 'signal': 'WAIT'};
  StreamSubscription<dynamic>? _sub;
  Timer? _tick;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _sub = widget.updates.listen((d) {
      if (d is Map && !d.containsKey('cmd')) setState(() => _data = d.cast<String, dynamic>());
    });
    // the window starts in its own engine: ask the app for the current state (a message sent before it was ready is lost)
    widget.send?.call({'cmd': 'hello'});
    final t = widget.ticker;
    if (t != null) {
      _tick = Timer.periodic(t, (_) {
        if (mounted && _data['live'] == true && _data['hide'] != true) setState(() {}); // countdowns
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_data['live'] == true) return _live(context);
    final lang = _data['lang'] as String? ?? 'ar';
    String t(String k) => tr(lang, k);
    final sig = _data['signal'] as String? ?? 'WAIT';
    final color = switch (sig) {
      'BUY' => SignalColors.buy,
      'SELL' => SignalColors.sell,
      _ => SignalColors.wait,
    };
    final conf = _data['confidence'] as num?;
    final s = t('seconds');
    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xEE111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color, width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    key: const Key('overlay_signal'),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      t(sig.toLowerCase()),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const Key('overlay_close'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${t('confidence')}: ${conf == null ? '—' : '${(conf * 100).round()}%'}'
                '${conf != null && _data['confidence_calibrated'] != true ? ' (${t('uncalibrated')})' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Text(
                '${t('duration')}: ${_data['duration_sec'] == null ? '—' : '${_data['duration_sec']}$s'}  ·  '
                '${t('timeframe')}: ${_data['timeframe_sec'] == null ? '—' : '${_data['timeframe_sec']}$s'}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                _data['state'] == null ? '' : t('state_${_data['state']}'),
                key: const Key('overlay_state'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _mmss(int sec) => '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

  /// The candle countdown, the entry window of a fresh signal, and the one-tap result of a finished trade.
  List<Widget> _timing(String Function(String) t, String sig) {
    final tf = (_data['timeframe_sec'] as num?)?.toInt() ?? 30;
    final nowMs = _now().millisecondsSinceEpoch;
    final nowS = nowMs ~/ 1000;
    final left = tf - nowS % tf; // seconds until this candle closes
    final at = (_data['signal_at'] as num?)?.toInt();
    final fresh = sig != 'WAIT' && at != null && at ~/ 1000 ~/ tf == nowS ~/ tf; // still the candle it was given in
    final out = <Widget>[
      Text(
        '${t('live_candle_left')}: ${_mmss(left)}',
        key: const Key('overlay_countdown'),
        style: const TextStyle(color: Colors.white70, fontSize: 11),
      ),
    ];
    if (sig != 'WAIT' && at != null) {
      out.add(
        Text(
          fresh ? '${t('live_enter_now')} — ${t('live_left')} ${_mmss(left)}' : t('live_entry_passed'),
          key: const Key('overlay_entry'),
          style: TextStyle(color: fresh ? Colors.lightGreenAccent : Colors.white54, fontWeight: FontWeight.bold, fontSize: 12),
        ),
      );
    }
    final pend = [for (final p in (_data['pending'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
    if (pend.isNotEmpty) {
      final p = pend.first;
      final rest = (((p['expires_at'] as num).toInt() - nowMs) / 1000).ceil();
      final side = t((p['side'] as String).toLowerCase());
      if (rest > 0) {
        out.add(
          Text(
            '${t('live_result_in')} ($side): ${_mmss(rest)}',
            key: const Key('overlay_result_wait'),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        );
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              key: const Key('overlay_result'),
              children: [
                Expanded(
                  child: Text('${t('live_how_did_it_go')} ($side)', style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
                for (final (o, c) in const [('win', SignalColors.buy), ('loss', SignalColors.sell), ('draw', Colors.blueGrey)])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 4),
                    child: FilledButton(
                      key: Key('overlay_result_$o'),
                      style: FilledButton.styleFrom(
                        backgroundColor: c,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => widget.send?.call({'cmd': 'result', 'id': p['id'], 'outcome': o}),
                      child: Text(t(o), style: const TextStyle(fontSize: 11)),
                    ),
                  ),
                IconButton(
                  key: const Key('overlay_result_skip'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16, color: Colors.white54),
                  onPressed: () => widget.send?.call({'cmd': 'skip_result', 'id': p['id']}),
                ),
              ],
            ),
          ),
        );
      }
    }
    return out;
  }

  static const _timeframes = [5, 10, 15, 30, 60, 120, 180, 300];
  static const _durations = [30, 60, 90, 120, 180, 300];

  /// Candle length and trade duration (stored with every signal and result, for the statistics by time), the fast
  /// reading switch, and demo / real for the one-tap results.
  List<Widget> _controls(String Function(String) t) {
    final tf = (_data['timeframe_sec'] as num?)?.toInt() ?? 30;
    final dur = (_data['duration_min_sec'] as num?)?.toInt() ?? 60;
    const style = TextStyle(color: Colors.white, fontSize: 11);
    Widget pick(String key, String label, int value, List<int> options, String cmd) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: const TextStyle(color: Colors.white70, fontSize: 11)),
        DropdownButton<int>(
          key: Key(key),
          value: options.contains(value) ? value : null,
          isDense: true,
          dropdownColor: const Color(0xFF1F2937),
          style: style,
          underline: const SizedBox.shrink(),
          items: [
            for (final o in options)
              DropdownMenuItem(
                value: o,
                child: Text('$o${t('seconds')}', style: style),
              ),
          ],
          onChanged: (v) => v == null ? null : widget.send?.call({'cmd': cmd, 'value': v}),
        ),
      ],
    );
    return [
      Wrap(
        spacing: 10,
        runSpacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          pick('overlay_tf', t('live_candle'), tf, _timeframes, 'set_tf'),
          pick('overlay_dur', t('live_trade'), dur, _durations, 'set_dur'),
        ],
      ),
      Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(t('live_fast'), style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Switch(
            key: const Key('overlay_fast'),
            value: _data['fast'] != false,
            onChanged: (v) => widget.send?.call({'cmd': 'fast', 'on': v}),
          ),
          for (final a in const ['demo', 'real'])
            ChoiceChip(
              key: Key('overlay_account_$a'),
              visualDensity: VisualDensity.compact,
              label: Text(t(a), style: const TextStyle(fontSize: 11)),
              selected: (_data['account'] ?? 'demo') == a,
              onSelected: (_) => widget.send?.call({'cmd': 'account', 'value': a}),
            ),
        ],
      ),
    ];
  }

  /// Live analysis over the trading app: last answer + "Analyse now" + "Auto".
  Widget _live(BuildContext context) {
    if (_data['hide'] == true) return const SizedBox.shrink(); // not in the screen picture
    final lang = _data['lang'] as String? ?? 'ar';
    String t(String k) => tr(lang, k);
    final sig = _data['signal'] as String? ?? 'WAIT';
    final color = switch (sig) {
      'BUY' => SignalColors.buy,
      'SELL' => SignalColors.sell,
      _ => SignalColors.wait,
    };
    final busy = _data['busy'] == true;
    final q = _data['quality'] as num?;
    final price = _data['price'];
    final dur = _data['duration_sec'];
    final send = widget.send;
    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xEE111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color, width: 2),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      key: const Key('overlay_signal'),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        t(sig.toLowerCase()),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (sig != 'WAIT' && dur != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$dur${t('seconds')}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                    const Spacer(),
                    if (_data['time'] != null)
                      Text('${_data['time']}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    IconButton(
                      key: const Key('overlay_close'),
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                      onPressed: () {
                        send?.call({'cmd': 'stop'});
                        widget.onClose();
                      },
                    ),
                  ],
                ),
                // the chart reading: direction + the next step (the tested-strategy signal stays in the badge above)
                if (_data['read_head'] != null && _data['error'] == null)
                  Container(
                    key: const Key('overlay_read'),
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: switch (_data['read_bias']) {
                          'up' => SignalColors.buy,
                          'down' => SignalColors.sell,
                          _ => SignalColors.wait,
                        },
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${t('read_title')}: ${_data['read_head']}',
                          style: TextStyle(
                            color: switch (_data['read_bias']) {
                              'up' => SignalColors.buy,
                              'down' => SignalColors.sell,
                              _ => Colors.amberAccent,
                            },
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        if ('${_data['read_step'] ?? ''}'.isNotEmpty)
                          Text(
                            '${_data['read_step']}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        for (final l in (_data['read_lines'] as List? ?? const []))
                          Text('• $l', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                if (_data['note'] != null && _data['error'] == null)
                  Text('${_data['note']}', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
                if (_data['error'] != null)
                  Text(
                    '${_data['error']}',
                    key: const Key('overlay_error'),
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
                  )
                else if (_data['reason'] != null)
                  Text(
                    '${_data['reason']}',
                    key: const Key('overlay_reason'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                if (q != null || price != null)
                  Text(
                    [
                      if (q != null) '${t('data_quality')}: ${(q * 100).round()}%',
                      if (price != null) '${t('live_price')}: $price',
                    ].join('  ·  '),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ..._timing(t, sig),
                ..._controls(t),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('overlay_analyze'),
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: busy ? null : () => send?.call({'cmd': 'analyze'}),
                        icon: busy
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.center_focus_strong, size: 18),
                        label: Text(t('live_analyze'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    IconButton(
                      key: const Key('overlay_frame'),
                      tooltip: t('live_set_frame'),
                      visualDensity: VisualDensity.compact,
                      onPressed: busy ? null : () => send?.call({'cmd': 'frame'}),
                      icon: const Icon(Icons.crop, color: Colors.white70, size: 20),
                    ),
                    Text(t('live_auto'), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    Switch(
                      key: const Key('overlay_auto'),
                      value: _data['auto'] == true,
                      onChanged: (v) => send?.call({'cmd': 'auto', 'on': v}),
                    ),
                  ],
                ),
                Text(
                  t('manual_only'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 9),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
