import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/companion.dart';
import '../../core/engine_api.dart';
import '../../l10n/strings.dart';

typedef PairFn = Future<CompanionPairing> Function(PairingLink link, String deviceName);

/// Phone / tablet first run: connect to the engine on the user's computer.
/// The QR code (or its link) comes from the computer: Settings → Companion devices.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.onPaired, this.pair = pairWithComputer, this.lang = 'ar',
      this.allowCamera = true});
  final ValueChanged<CompanionPairing> onPaired;
  final PairFn pair;
  final String lang;
  final bool allowCamera;
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _link = TextEditingController();
  final _name = TextEditingController(text: 'Phone');
  bool _scanning = false;
  bool _busy = false;
  String? _error;

  String t(String k) => tr(widget.lang, k);

  Future<void> _submit([String? text]) async {
    final link = PairingLink.tryParse(text ?? _link.text);
    if (link == null) {
      setState(() => _error = t('pair_invalid_link'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _scanning = false;
    });
    try {
      final p = await widget.pair(link, _name.text.trim().isEmpty ? 'Phone' : _name.text.trim());
      await CompanionStore.save(p);
      widget.onPaired(p);
    } on EngineException catch (e) {
      setState(() => _error = '${t('pair_failed')}: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: widget.lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: Text(t('pair_title'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(t('pair_intro')),
          const SizedBox(height: 16),
          TextField(key: const Key('pair_name'), controller: _name, decoration: InputDecoration(labelText: t('pair_device_name'))),
          const SizedBox(height: 16),
          if (widget.allowCamera && _scanning)
            SizedBox(
              height: 280,
              child: MobileScanner(onDetect: (capture) {
                for (final b in capture.barcodes) {
                  final v = b.rawValue;
                  if (v != null && PairingLink.tryParse(v) != null && !_busy) {
                    _submit(v);
                    return;
                  }
                }
              }),
            )
          else if (widget.allowCamera)
            FilledButton.icon(
              key: const Key('btn_scan'),
              onPressed: _busy ? null : () => setState(() => _scanning = true),
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(t('pair_scan')),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('pair_link'),
            controller: _link,
            decoration: InputDecoration(labelText: t('pair_paste_link'), hintText: 'uata://pair?...'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(key: const Key('btn_pair'), onPressed: _busy ? null : _submit, child: Text(t('pair_connect'))),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, key: const Key('pair_error'), style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 24),
          Text(t('pair_privacy'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
