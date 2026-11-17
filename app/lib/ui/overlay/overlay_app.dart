import 'dart:async';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';

/// UI of the Android floating window. Runs in its own Flutter engine and
/// receives state from the main app through [FlutterOverlayWindow.shareData].
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key, this.updates, this.onClose});

  /// Payload stream; defaults to the overlay channel. Injectable for tests.
  final Stream<dynamic>? updates;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        home: Material(
          color: Colors.transparent,
          child: OverlayCard(
            updates: updates ?? FlutterOverlayWindow.overlayListener,
            onClose: onClose ?? () => FlutterOverlayWindow.closeOverlay(),
          ),
        ),
      );
}

class OverlayCard extends StatefulWidget {
  const OverlayCard({super.key, required this.updates, required this.onClose});
  final Stream<dynamic> updates;
  final VoidCallback onClose;

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
}
