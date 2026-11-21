import 'dart:async';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';

/// UI of the Android floating window. Runs in its own Flutter engine and
/// receives state from the main app through [FlutterOverlayWindow.shareData].
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key, this.updates, this.onClose, this.send});

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
            updates: updates ?? FlutterOverlayWindow.overlayListener,
            onClose: onClose ?? () => FlutterOverlayWindow.closeOverlay(),
            send: send ?? (m) => FlutterOverlayWindow.shareData(m),
          ),
        ),
      );
}

class OverlayCard extends StatefulWidget {
  const OverlayCard({super.key, required this.updates, required this.onClose, this.send});
  final Stream<dynamic> updates;
  final VoidCallback onClose;
  final void Function(Json)? send;

  @override
  State<OverlayCard> createState() => _OverlayCardState();
}

class _OverlayCardState extends State<OverlayCard> {
  Json _data = const {'lang': 'ar', 'state': 'idle', 'signal': 'WAIT'};
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.updates.listen((d) {
      if (d is Map) setState(() => _data = d.cast<String, dynamic>());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_data['live'] == true) return _live(context);
    final lang = _data['lang'] as String? ?? 'ar';
    String t(String k) => tr(lang, k);
    final sig = _data['signal'] as String? ?? 'WAIT';
    final color = switch (sig) { 'BUY' => SignalColors.buy, 'SELL' => SignalColors.sell, _ => SignalColors.wait };
    final conf = _data['confidence'] as num?;
    final s = t('seconds');
    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xEE111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 2)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(
                key: const Key('overlay_signal'),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                child: Text(t(sig.toLowerCase()), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const Spacer(),
              IconButton(
                key: const Key('overlay_close'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                onPressed: widget.onClose,
              ),
            ]),
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
            Text(t('state_${_data['state']}'),
                key: const Key('overlay_state'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  /// Live analysis over the trading app: last answer + "Analyse now" + "Auto".
  Widget _live(BuildContext context) {
    if (_data['hide'] == true) return const SizedBox.shrink(); // not in the screen picture
    final lang = _data['lang'] as String? ?? 'ar';
    String t(String k) => tr(lang, k);
    final sig = _data['signal'] as String? ?? 'WAIT';
    final color = switch (sig) { 'BUY' => SignalColors.buy, 'SELL' => SignalColors.sell, _ => SignalColors.wait };
    final busy = _data['busy'] == true;
    final q = _data['quality'] as num?;
    final price = _data['price'];
    final dur = _data['duration_sec'];
    final send = widget.send;
    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Card(
        color: const Color(0xEE111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 2)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                key: const Key('overlay_signal'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                child: Text(t(sig.toLowerCase()), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              if (sig != 'WAIT' && dur != null) ...[
                const SizedBox(width: 6),
                Text('$dur${t('seconds')}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
              const Spacer(),
              if (_data['time'] != null) Text('${_data['time']}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
              IconButton(
                key: const Key('overlay_close'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                onPressed: () {
                  send?.call({'cmd': 'stop'});
                  widget.onClose();
                },
              ),
            ]),
            if (_data['note'] != null && _data['error'] == null)
              Text('${_data['note']}', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
            if (_data['error'] != null)
              Text('${_data['error']}', key: const Key('overlay_error'), style: const TextStyle(color: Colors.orangeAccent, fontSize: 11))
            else if (_data['reason'] != null)
              Text('${_data['reason']}', key: const Key('overlay_reason'), maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            if (q != null || price != null)
              Text([
                if (q != null) '${t('data_quality')}: ${(q * 100).round()}%',
                if (price != null) '${t('live_price')}: $price',
              ].join('  ·  '), style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 4),
            Row(children: [
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
            ]),
            Text(t('manual_only'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38, fontSize: 9)),
          ]),
        ),
      ),
    );
  }
}
