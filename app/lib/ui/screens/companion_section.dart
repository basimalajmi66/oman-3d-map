import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/engine_api.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Desktop settings: let the user's phone / tablet use this computer's engine.
/// Off by default; pairing needs a one-time code shown here as a QR code.
class CompanionDevicesSection extends StatefulWidget {
  const CompanionDevicesSection({super.key});
  @override
  State<CompanionDevicesSection> createState() => _CompanionDevicesSectionState();
}

class _CompanionDevicesSectionState extends State<CompanionDevicesSection> {
  Json _status = const {};
  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final s = await app.engine.companionStatus();
      if (mounted) setState(() => _status = s);
    } on EngineException {
      // engine offline: the panel already says so
    }
  }

  Future<void> _toggle(bool on) async {
    await runWithFeedback(context, () => app.updateSettings({'companion_enabled': on}));
    await _load();
  }

  Future<void> _pair() async {
    Json? p;
    await runWithFeedback(context, () async => p = await app.engine.companionPairing());
    if (p == null || !mounted) return;
    await showDialog<void>(context: context, builder: (_) => _PairingDialog(pairing: p!, app: app));
    await app.engine.cancelCompanionPairing().catchError((_) {});
    await _load();
  }

  Future<void> _revoke(Json d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(app.t('companion_revoke')),
        content: Text('${d['name']}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
          FilledButton(key: const Key('confirm_revoke'), onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('companion_revoke'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runWithFeedback(context, () async {
      final s = await app.engine.revokeCompanionDevice(d['id'] as int);
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final enabled = app.settings['companion_enabled'] == true;
    final running = _status['running'] == true;
    final devices = ((_status['devices'] as List?) ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>());
    final active = devices.where((d) => d['revoked_at'] == null).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        key: const Key('companion_toggle'),
        secondary: const Icon(Icons.phonelink_outlined),
        title: Text(app.t('companion_enable')),
        subtitle: Text(app.t('companion_hint')),
        value: enabled,
        onChanged: _toggle,
      ),
      if (enabled && _status['error'] != null)
        ListTile(
          dense: true,
          leading: const Icon(Icons.error_outline, color: SignalColors.sell),
          title: Text('${_status['error']}'),
        ),
      if (enabled && running) ...[
        ListTile(
          dense: true,
          leading: const Icon(Icons.lan_outlined),
          title: Text(app.t('companion_listening')),
          subtitle: Text('${((_status['addresses'] as List?) ?? const []).join(', ')} : ${_status['port']}  ·  TLS'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const Key('btn_pair_device'),
              onPressed: _pair,
              icon: const Icon(Icons.qr_code_2),
              label: Text(app.t('companion_pair')),
            ),
          ),
        ),
      ],
      for (final d in active)
        ListTile(
          key: Key('device_${d['id']}'),
          dense: true,
          leading: const Icon(Icons.smartphone),
          title: Text('${d['name']}'),
          subtitle: Text('${app.t('companion_last_seen')}: ${d['last_seen_at'] ?? '—'}'),
          trailing: IconButton(
            key: Key('revoke_${d['id']}'),
            tooltip: app.t('companion_revoke'),
            icon: const Icon(Icons.link_off),
            onPressed: () => _revoke(d),
          ),
        ),
    ]);
  }
}

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.pairing, required this.app});
  final Json pairing;
  final AppState app;
  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  late int _left = widget.pairing['expires_in_sec'] as int? ?? 300;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = _left > 0 ? _left - 1 : 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final p = widget.pairing;
    final expired = _left == 0;
    return AlertDialog(
      title: Text(app.t('companion_pair')),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!expired)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(key: const Key('pair_qr'), data: p['uri'] as String, size: 220),
            )
          else
            Padding(padding: const EdgeInsets.all(24), child: Text(app.t('companion_code_expired'))),
          const SizedBox(height: 8),
          Text(app.t('companion_scan_hint'), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          SelectableText('${p['host']}:${p['port']}  ·  ${app.t('companion_code')}: ${p['code']}',
              key: const Key('pair_code'), textAlign: TextAlign.center),
          Text('${app.t('companion_expires_in')} ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}'),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('close')))],
    );
  }
}
