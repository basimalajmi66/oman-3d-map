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
        child: SingleChildScrollView(
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

  /// The strip on a wide screen: two tidy rows, each scaled down rather than overflowing.
  ///   row 1: signal │ candle countdown (+ enter now) │ win · loss · draw │ analyse now │ auto │ ✕
  ///   row 2: reason / chart reading │ candle ▾ │ trade ▾ │ demo · real │ fast │ frame
  Widget _strip(
    String Function(String) t,
    String sig,
    Color color,
    bool busy,
    Object? dur,
    int left,
    bool fresh,
    int? at,
    Map<String, dynamic>? p0,
    int rest,
    bool due,
    Map<String, dynamic>? target,
    Widget close,
  ) {
    final send = widget.send;
    const small = TextStyle(color: Colors.white70, fontSize: 12);
    const value = TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600);
    Widget gap([double w = 10]) => SizedBox(width: w);
    Widget sep() => Container(width: 1, height: 30, margin: const EdgeInsets.symmetric(horizontal: 8), color: Colors.white24);

    Widget pick(String key, String label, int v, List<int> options, String cmd) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: small),
        DropdownButton<int>(
          key: Key(key),
          value: options.contains(v) ? v : null,
          isDense: true,
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

    Widget seg(String a) {
      final on = (_data['account'] ?? 'demo') == a;
      return InkWell(
        key: Key('overlay_account_$a'),
        onTap: () => send?.call({'cmd': 'account', 'value': a}),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: on ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white38),
          ),
          child: Text(
            t(a),
            style: TextStyle(fontSize: 12, color: on ? Colors.black : Colors.white70, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }

    final running = p0 != null && rest > 0 && !due;
    final quickTitle = due
        ? '${t('live_how_did_it_go')} (${t((p0!['side'] as String).toLowerCase())})'
        : target != null
        ? '${t('live_quick_result')} (${t((target['side'] as String).toLowerCase())})'
              '${running ? ' · ${t('live_result_in')} ${_mmss(rest)}' : ''}'
        : t('live_quick_result');

    final row1 = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // the signal
        Container(
          key: const Key('overlay_signal'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          child: Text(
            sig != 'WAIT' && dur != null ? '${t(sig.toLowerCase())} · $dur${t('seconds')}' : t(sig.toLowerCase()),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
          ),
        ),
        sep(),
        // the candle countdown and the entry window
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _mmss(left),
              key: const Key('overlay_countdown'),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (sig != 'WAIT' && at != null)
              Text(
                fresh ? t('live_enter_now') : t('live_entry_passed_short'),
                key: const Key('overlay_entry'),
                style: TextStyle(
                  color: fresh ? Colors.lightGreenAccent : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
        sep(),
        // the quick result
        Column(
          key: const Key('overlay_quick'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              quickTitle,
              key: due
                  ? const Key('overlay_result')
                  : running
                  ? const Key('overlay_result_wait')
                  : null,
              style: TextStyle(
                color: due ? Colors.amberAccent : Colors.white60,
                fontSize: 11,
                fontWeight: due ? FontWeight.bold : null,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (o, c) in const [
                  ('win', SignalColors.buy),
                  ('loss', SignalColors.sell),
                  ('draw', Colors.blueGrey),
                ]) ...[
                  FilledButton(
                    key: Key('overlay_result_$o'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c,
                      minimumSize: const Size(64, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => send?.call(
                      due ? {'cmd': 'result', 'id': p0!['id'], 'outcome': o} : {'cmd': 'quick_result', 'outcome': o},
                    ),
                    child: Text(t(o), style: const TextStyle(fontSize: 13)),
                  ),
                  gap(4),
                ],
                if (target != null)
                  IconButton(
                    key: const Key('overlay_result_skip'),
                    tooltip: t('live_not_taken'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => send?.call({'cmd': 'skip_result', 'id': target['id']}),
                    icon: const Icon(Icons.block, size: 18, color: Colors.white54),
                  ),
              ],
            ),
          ],
        ),
        sep(),
        // actions
        FilledButton.icon(
          key: const Key('overlay_analyze'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
          onPressed: busy ? null : () => send?.call({'cmd': 'analyze'}),
          icon: busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.center_focus_strong, size: 18),
          label: Text(t('live_analyze'), style: const TextStyle(fontSize: 14)),
        ),
        gap(6),
        Text(t('live_auto'), style: small),
        Switch(
          key: const Key('overlay_auto'),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          value: _data['auto'] == true,
          onChanged: (v) => send?.call({'cmd': 'auto', 'on': v}),
        ),
        close,
      ],
    );

    final info = _data['error'] != null
        ? Text(
            '${_data['error']}',
            key: const Key('overlay_error'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
          )
        : _data['note'] != null
        ? Text(
            '${_data['note']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 12),
          )
        : _data['reason'] != null && sig != 'WAIT'
        ? Text(
            '${_data['reason']}',
            key: const Key('overlay_reason'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          )
        : Text(
            '${t('read_title')}: ${_data['read_head'] ?? '—'}${'${_data['read_step'] ?? ''}'.isNotEmpty ? ' — ${_data['read_step']}' : ''}'
            '${(_data['read_lines'] as List? ?? const []).isNotEmpty ? ' • ${(_data['read_lines'] as List).first}' : ''}',
            key: const Key('overlay_read'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _data['read_bias'] == 'up' || _data['read_bias'] == 'down'
                  ? _sideColor(_data['read_bias'] as String?)
                  : Colors.amberAccent,
            ),
          );

    final row2 = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 380, child: info),
        if (_data['price'] != null) ...[
          sep(),
          Text('${t('live_price')}: ${_data['price']}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
        sep(),
        pick('overlay_tf', t('live_candle'), (_data['timeframe_sec'] as num?)?.toInt() ?? 30, _timeframes, 'set_tf'),
        gap(),
        pick('overlay_dur', t('live_trade'), (_data['duration_min_sec'] as num?)?.toInt() ?? 60, _durations, 'set_dur'),
        sep(),
        seg('demo'),
        gap(4),
        seg('real'),
        sep(),
        Text(t('live_fast'), style: small),
        Switch(
          key: const Key('overlay_fast'),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          value: _data['fast'] != false,
          onChanged: (v) => send?.call({'cmd': 'fast', 'on': v}),
        ),
        IconButton(
          key: const Key('overlay_frame'),
          tooltip: t('live_set_frame'),
          visualDensity: VisualDensity.compact,
          onPressed: busy ? null : () => send?.call({'cmd': 'frame'}),
          icon: const Icon(Icons.crop, color: Colors.white70, size: 20),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: row1),
          ),
          const Divider(height: 6, color: Colors.white12),
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: row2),
          ),
        ],
      ),
    );
  }

  /// Live analysis over the trading app. On a wide window (the tablet) a low horizontal strip of sections, side by
  /// side: signal | timing | quick result | chart reading | candle & trade | actions. On a narrow window the same
  /// sections stacked.
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

    final tf = (_data['timeframe_sec'] as num?)?.toInt() ?? 30;
    final nowMs = _now().millisecondsSinceEpoch;
    final nowS = nowMs ~/ 1000;
    final left = tf - nowS % tf;
    final at = (_data['signal_at'] as num?)?.toInt();
    final fresh = sig != 'WAIT' && at != null && at ~/ 1000 ~/ tf == nowS ~/ tf;
    final pend = [for (final p in (_data['pending'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
    final p0 = pend.isEmpty ? null : pend.first;
    final rest = p0 == null ? 0 : (((p0['expires_at'] as num).toInt() - nowMs) / 1000).ceil();
    final target = (_data['quick_target'] as Map?)?.cast<String, dynamic>();

    const small = TextStyle(color: Colors.white70, fontSize: 11);
    const value = TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600);

    Widget pick(String key, String label, int v, List<int> options, String cmd) => Row(
      children: [
        Expanded(
          child: Text(label, style: small, overflow: TextOverflow.ellipsis),
        ),
        DropdownButton<int>(
          key: Key(key),
          value: options.contains(v) ? v : null,
          isDense: true,
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

    // ---------------- sections
    final signal = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('overlay_signal'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
          child: Column(
            children: [
              Text(
                t(sig.toLowerCase()),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
              ),
              if (sig != 'WAIT' && dur != null)
                Text('${t('live_trade')}: $dur${t('seconds')}', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
        if (_data['error'] != null)
          Text(
            '${_data['error']}',
            key: const Key('overlay_error'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
          )
        else if (_data['reason'] != null)
          Text(
            '${_data['reason']}',
            key: const Key('overlay_reason'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        if (_data['note'] != null && _data['error'] == null)
          Text(
            '${_data['note']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11),
          ),
      ],
    );

    final timing = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('live_candle_left'), style: small, textAlign: TextAlign.center),
        Text(
          _mmss(left),
          key: const Key('overlay_countdown'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        if (sig != 'WAIT' && at != null)
          Text(
            fresh ? t('live_enter_now') : t('live_entry_passed'),
            key: const Key('overlay_entry'),
            maxLines: 2,
            textAlign: TextAlign.center,
            style: TextStyle(color: fresh ? Colors.lightGreenAccent : Colors.white54, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        if (p0 != null && rest > 0)
          Text(
            '${t('live_result_in')}: ${_mmss(rest)}',
            key: const Key('overlay_result_wait'),
            style: small,
            textAlign: TextAlign.center,
          ),
      ],
    );

    // the quick result buttons — always there; they record the open trade (or the latest signal)
    final due = p0 != null && rest <= 0;
    final quick = Column(
      key: const Key('overlay_quick'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          due
              ? '${t('live_how_did_it_go')} (${t((p0['side'] as String).toLowerCase())})'
              : target != null
              ? '${t('live_quick_result')} (${t((target['side'] as String).toLowerCase())})'
              : t('live_quick_result'),
          key: due ? const Key('overlay_result') : null,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: due ? Colors.amberAccent : Colors.white70,
            fontSize: 11,
            fontWeight: due ? FontWeight.bold : null,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            for (final (o, c) in const [('win', SignalColors.buy), ('loss', SignalColors.sell), ('draw', Colors.blueGrey)])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FilledButton(
                    key: Key('overlay_result_$o'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: () =>
                        send?.call(due ? {'cmd': 'result', 'id': p0['id'], 'outcome': o} : {'cmd': 'quick_result', 'outcome': o}),
                    child: Text(t(o), style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
          ],
        ),
        if (target != null)
          TextButton(
            key: const Key('overlay_result_skip'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 24),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => send?.call({'cmd': 'skip_result', 'id': target['id']}),
            child: Text(t('live_not_taken'), style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ),
      ],
    );

    final reading = Column(
      key: const Key('overlay_read'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${t('read_title')}: ${_data['read_head'] ?? '—'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _data['read_bias'] == 'up' || _data['read_bias'] == 'down'
                ? _sideColor(_data['read_bias'] as String?)
                : Colors.amberAccent,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        if ('${_data['read_step'] ?? ''}'.isNotEmpty)
          Text(
            '${_data['read_step']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        for (final l in (_data['read_lines'] as List? ?? const []).take(2))
          Text('• $l', maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
        if (q != null || price != null)
          Text(
            [
              if (q != null) '${t('data_quality')}: ${(q * 100).round()}%',
              if (price != null) '${t('live_price')}: $price',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
      ],
    );

    final settings = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        pick('overlay_tf', t('live_candle'), tf, _timeframes, 'set_tf'),
        pick('overlay_dur', t('live_trade'), (_data['duration_min_sec'] as num?)?.toInt() ?? 60, _durations, 'set_dur'),
        Row(
          children: [
            for (final a in const ['demo', 'real'])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: ChoiceChip(
                    key: Key('overlay_account_$a'),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                    label: SizedBox(
                      width: double.infinity,
                      child: Text(t(a), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                    ),
                    selected: (_data['account'] ?? 'demo') == a,
                    onSelected: (_) => send?.call({'cmd': 'account', 'value': a}),
                  ),
                ),
              ),
          ],
        ),
      ],
    );

    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('overlay_analyze'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10), minimumSize: const Size(0, 38)),
          onPressed: busy ? null : () => send?.call({'cmd': 'analyze'}),
          icon: busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.center_focus_strong, size: 18),
          label: Text(t('live_analyze'), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ),
        Row(
          children: [
            IconButton(
              key: const Key('overlay_frame'),
              tooltip: t('live_set_frame'),
              visualDensity: VisualDensity.compact,
              onPressed: busy ? null : () => send?.call({'cmd': 'frame'}),
              icon: const Icon(Icons.crop, color: Colors.white70, size: 20),
            ),
            Expanded(
              child: Text(t('live_auto'), style: small, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                key: const Key('overlay_auto'),
                value: _data['auto'] == true,
                onChanged: (v) => send?.call({'cmd': 'auto', 'on': v}),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(t('live_fast'), style: small, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                key: const Key('overlay_fast'),
                value: _data['fast'] != false,
                onChanged: (v) => send?.call({'cmd': 'fast', 'on': v}),
              ),
            ),
          ],
        ),
      ],
    );

    final close = IconButton(
      key: const Key('overlay_close'),
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
      onPressed: () {
        send?.call({'cmd': 'stop'});
        widget.onClose();
      },
    );

    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xF0111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color, width: 2),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= 560) return _strip(t, sig, color, busy, dur, left, fresh, at, p0, rest, due, target, close);
            // narrow: the same sections stacked
            Widget box(Widget child) => Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(10)),
              child: child,
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        _data['time'] != null ? '${_data['time']}' : '',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      const Spacer(),
                      close,
                    ],
                  ),
                  signal,
                  box(timing),
                  box(quick),
                  box(reading),
                  box(settings),
                  const SizedBox(height: 6),
                  actions,
                  Text(
                    t('manual_only'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
