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

  static const _timeframes = [5, 10, 15, 30, 60, 120, 180, 300];
  static const _durations = [30, 60, 90, 120, 180, 300];
  static const _panel = Color(0xFF1F2937);

  Color _sideColor(String? side) => switch (side) {
    'BUY' || 'up' => SignalColors.buy,
    'SELL' || 'down' => SignalColors.sell,
    _ => SignalColors.wait,
  };

  /// A section of the tall window: a rounded box with an optional small title.
  Widget _box({Key? key, String? title, Color? border, required List<Widget> children}) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(10),
      border: border == null ? null : Border.all(color: border, width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ...children,
      ],
    ),
  );

  /// Live analysis over the trading app — a tall, narrow window, top to bottom:
  /// signal → timing (candle countdown, enter now, trade result) → chart reading → candle / trade / fast / account →
  /// analyse now, frame, auto.
  Widget _live(BuildContext context) {
    if (_data['hide'] == true) return const SizedBox.shrink(); // not in the screen picture
    final lang = _data['lang'] as String? ?? 'ar';
    String t(String k) => tr(lang, k);
    final sig = _data['signal'] as String? ?? 'WAIT';
    final color = _sideColor(sig);
    final busy = _data['busy'] == true;
    final q = _data['quality'] as num?;
    final price = _data['price'];
    final dur = _data['duration_sec'];
    final send = widget.send;

    // --- timing
    final tf = (_data['timeframe_sec'] as num?)?.toInt() ?? 30;
    final nowMs = _now().millisecondsSinceEpoch;
    final nowS = nowMs ~/ 1000;
    final left = tf - nowS % tf;
    final at = (_data['signal_at'] as num?)?.toInt();
    final fresh = sig != 'WAIT' && at != null && at ~/ 1000 ~/ tf == nowS ~/ tf;
    final pend = [for (final p in (_data['pending'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
    final p0 = pend.isEmpty ? null : pend.first;
    final rest = p0 == null ? 0 : (((p0['expires_at'] as num).toInt() - nowMs) / 1000).ceil();

    const small = TextStyle(color: Colors.white70, fontSize: 12);
    const value = TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600);
    Widget pick(String key, String label, int v, List<int> options, String cmd) => Row(
      children: [
        Expanded(child: Text(label, style: small)),
        DropdownButton<int>(
          key: Key(key),
          value: options.contains(v) ? v : null,
          dropdownColor: _panel,
          style: value,
          underline: const SizedBox.shrink(),
          items: [
            for (final o in options)
              DropdownMenuItem(
                value: o,
                child: Text('$o${t('seconds')}', style: value),
              ),
          ],
          onChanged: (x) => x == null ? null : send?.call({'cmd': cmd, 'value': x}),
        ),
      ],
    );

    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xF0111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color, width: 2),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------------- the signal
              Row(
                children: [
                  Text(
                    _data['time'] != null ? '${_data['time']}' : '',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const Key('overlay_close'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                    onPressed: () {
                      send?.call({'cmd': 'stop'});
                      widget.onClose();
                    },
                  ),
                ],
              ),
              Container(
                key: const Key('overlay_signal'),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  children: [
                    Text(
                      t(sig.toLowerCase()),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
                    ),
                    if (sig != 'WAIT' && dur != null)
                      Text('${t('live_trade')}: $dur${t('seconds')}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              if (_data['error'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${_data['error']}',
                    key: const Key('overlay_error'),
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                  ),
                )
              else if (_data['reason'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${_data['reason']}',
                    key: const Key('overlay_reason'),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              if (_data['note'] != null && _data['error'] == null)
                Text(
                  '${_data['note']}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 12),
                ),

              // ---------------- timing
              _box(
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(t('live_candle_left'), style: small)),
                      Text(
                        _mmss(left),
                        key: const Key('overlay_countdown'),
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  if (sig != 'WAIT' && at != null)
                    Text(
                      fresh ? '${t('live_enter_now')} — ${t('live_left')} ${_mmss(left)}' : t('live_entry_passed'),
                      key: const Key('overlay_entry'),
                      style: TextStyle(
                        color: fresh ? Colors.lightGreenAccent : Colors.white54,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  if (p0 != null && rest > 0)
                    Text(
                      '${t('live_result_in')} (${t((p0['side'] as String).toLowerCase())}): ${_mmss(rest)}',
                      key: const Key('overlay_result_wait'),
                      style: small,
                    ),
                ],
              ),
              if (p0 != null && rest <= 0)
                _box(
                  key: const Key('overlay_result'),
                  border: Colors.amberAccent,
                  title: '${t('live_how_did_it_go')} (${t((p0['side'] as String).toLowerCase())})',
                  children: [
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (final (o, c) in const [
                          ('win', SignalColors.buy),
                          ('loss', SignalColors.sell),
                          ('draw', Colors.blueGrey),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: FilledButton(
                                key: Key('overlay_result_$o'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: c,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: () => send?.call({'cmd': 'result', 'id': p0['id'], 'outcome': o}),
                                child: Text(t(o), style: const TextStyle(fontSize: 13)),
                              ),
                            ),
                          ),
                      ],
                    ),
                    TextButton(
                      key: const Key('overlay_result_skip'),
                      onPressed: () => send?.call({'cmd': 'skip_result', 'id': p0['id']}),
                      child: Text(t('live_not_taken'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                  ],
                ),

              // ---------------- the chart reading
              if (_data['read_head'] != null && _data['error'] == null)
                _box(
                  key: const Key('overlay_read'),
                  border: _sideColor(_data['read_bias'] as String?),
                  children: [
                    Text(
                      '${t('read_title')}: ${_data['read_head']}',
                      style: TextStyle(
                        color: _data['read_bias'] == 'up' || _data['read_bias'] == 'down'
                            ? _sideColor(_data['read_bias'] as String?)
                            : Colors.amberAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    if ('${_data['read_step'] ?? ''}'.isNotEmpty)
                      Text(
                        '${_data['read_step']}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    for (final l in (_data['read_lines'] as List? ?? const [])) Text('• $l', style: small),
                  ],
                ),
              if (q != null || price != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    [
                      if (q != null) '${t('data_quality')}: ${(q * 100).round()}%',
                      if (price != null) '${t('live_price')}: $price',
                    ].join('  ·  '),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),

              // ---------------- settings: candle / trade / fast / account
              _box(
                children: [
                  pick('overlay_tf', t('live_candle'), tf, _timeframes, 'set_tf'),
                  pick('overlay_dur', t('live_trade'), (_data['duration_min_sec'] as num?)?.toInt() ?? 60, _durations, 'set_dur'),
                  Row(
                    children: [
                      Expanded(child: Text(t('live_fast'), style: small)),
                      Switch(
                        key: const Key('overlay_fast'),
                        value: _data['fast'] != false,
                        onChanged: (v) => send?.call({'cmd': 'fast', 'on': v}),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      for (final a in const ['demo', 'real'])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ChoiceChip(
                              key: Key('overlay_account_$a'),
                              label: SizedBox(
                                width: double.infinity,
                                child: Text(t(a), textAlign: TextAlign.center),
                              ),
                              selected: (_data['account'] ?? 'demo') == a,
                              onSelected: (_) => send?.call({'cmd': 'account', 'value': a}),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),

              // ---------------- actions
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('overlay_analyze'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: busy ? null : () => send?.call({'cmd': 'analyze'}),
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.center_focus_strong, size: 20),
                label: Text(t('live_analyze'), style: const TextStyle(fontSize: 15)),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('overlay_frame'),
                      onPressed: busy ? null : () => send?.call({'cmd': 'frame'}),
                      icon: const Icon(Icons.crop, size: 18),
                      label: Text(t('live_set_frame'), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(t('live_auto'), style: small),
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
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
