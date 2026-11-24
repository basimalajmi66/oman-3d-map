import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'companion_section.dart';
import 'knowledge_screen.dart' show FilePickFn, pickDeviceFile;

/// The GitHub Actions run that built this app (compare with the run you downloaded); 'dev' for local builds.
const appBuild = String.fromEnvironment('UATA_BUILD', defaultValue: 'dev');

const _timeframes = [5, 10, 15, 30, 60, 120, 180, 300, 900, 1800, 3600, 14400, 86400];
const _durations = [30, 60, 90, 120, 180, 300, 600, 900];
const _cooldowns = [0, 15, 30, 60, 120, 300];
const _indicators = [
  'price_action', 'candlesticks', 'support_resistance', 'trend', 'supply_demand', 'liquidity_zones', //
  'moving_averages', 'rsi', 'macd', 'bollinger_bands', 'atr', 'volume', 'momentum', 'volatility', 'chart_patterns',
];

/// Every user setting is editable here and persisted by the engine.
typedef SaveFileFn = Future<bool> Function(String name, List<int> bytes);

/// Save a copy wherever the user chooses (Downloads, a cloud drive, …) through the system dialog.
Future<bool> saveDeviceFile(String name, List<int> bytes) async =>
    await FilePicker.saveFile(fileName: name, bytes: Uint8List.fromList(bytes)) != null;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.pickFile = pickDeviceFile, this.saveFile = saveDeviceFile});
  final FilePickFn pickFile;
  final SaveFileFn saveFile;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Json> _backups = [];
  final Map<String, double> _drag = {};

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    final a = AppScope.read(context);
    if (!a.isCompanion && a.has('backups')) WidgetsBinding.instance.addPostFrameCallback((_) => _loadBackups());
  }

  Future<void> _loadBackups() async {
    await runWithFeedback(context, () async {
      final b = await app.engine.listBackups();
      if (mounted) setState(() => _backups = b);
    });
  }

  Future<void> _set(String key, Object value) =>
      runWithFeedback(context, () => app.updateSettings({key: value == 'null' ? null : value}));

  String _tfLabel(int s) => s < 60 ? '$s${app.t('seconds')}' : s < 3600 ? '${s ~/ 60}m' : s < 86400 ? '${s ~/ 3600}h' : '1D';

  Widget _slider(String key, String label, double min, double max, int divisions, {bool percent = true}) {
    final v = _drag[key] ?? (app.settings[key] as num?)?.toDouble() ?? min;
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        key: Key('slider_$key'),
        value: v.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: percent ? '${(v * 100).round()}%' : v.toStringAsFixed(2),
        onChanged: (x) => setState(() => _drag[key] = x),
        onChangeEnd: (x) async {
          await _set(key, double.parse(x.toStringAsFixed(2)));
          if (mounted) setState(() => _drag.remove(key));
        },
      ),
      trailing: Text(percent ? '${(v * 100).round()}%' : v.toStringAsFixed(2)),
    );
  }

  Widget _dropdown<T>(String key, String label, List<T> options, String Function(T) fmt) {
    final current = app.settings[key] as T?;
    return ListTile(
      title: Text(label),
      trailing: DropdownButton<T>(
        key: Key('dd_$key'),
        value: options.contains(current) ? current : null,
        items: options.map((o) => DropdownMenuItem<T>(value: o, child: Text(fmt(o)))).toList(),
        onChanged: (v) => v == null ? null : _set(key, v as Object),
      ),
    );
  }

  Future<void> _togglePermission(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(app.t('screen_permission')),
          content: Text(app.t('screen_permission_desc')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
            FilledButton(key: const Key('grant_screen'), onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('save'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _set('screen_capture_allowed', v);
  }

  Future<String?> _askPassphrase({required bool confirm}) async {
    final c1 = TextEditingController(), c2 = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final ok = c1.text.length >= 10 && (!confirm || c1.text == c2.text);
        return AlertDialog(
          title: Text(app.t(confirm ? 'create_backup' : 'restore_backup')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(app.t(confirm ? 'passphrase_warning' : 'restore_warning'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('pass1'),
                controller: c1,
                obscureText: true,
                decoration: InputDecoration(labelText: app.t('passphrase')),
                onChanged: (_) => setLocal(() {})),
            if (confirm) ...[
              const SizedBox(height: 8),
              TextField(
                  key: const Key('pass2'),
                  controller: c2,
                  obscureText: true,
                  decoration: InputDecoration(labelText: app.t('passphrase')),
                  onChanged: (_) => setLocal(() {})),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('cancel'))),
            FilledButton(key: const Key('pass_ok'), onPressed: ok ? () => Navigator.pop(ctx, c1.text) : null, child: Text(app.t('save'))),
          ],
        );
      }),
    );
  }

  Future<void> _createBackup() async {
    final p = await _askPassphrase(confirm: true);
    if (p == null || !mounted) return;
    await runWithFeedback(context, () => app.engine.createBackup(p), successKey: 'backup_created');
    await _loadBackups();
  }

  Future<void> _restore() async {
    final f = await widget.pickFile();
    if (f == null || !mounted) return;
    final p = await _askPassphrase(confirm: false);
    if (p == null || !mounted) return;
    await runWithFeedback(context, () async {
      await app.stopBackground(); // the service must not keep the old database open
      await app.engine.restoreBackup(f, p);
      await app.refresh();
    }, successKey: 'restored');
  }

  Future<void> _wipe() async {
    final c = TextEditingController();
    var includeBackups = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(app.t('wipe')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(app.t('wipe_confirm')),
            const SizedBox(height: 8),
            TextField(key: const Key('wipe_text'), controller: c, onChanged: (_) => setLocal(() {})),
            CheckboxListTile(
              value: includeBackups,
              onChanged: (v) => setLocal(() => includeBackups = v ?? false),
              title: Text(app.t('include_backups')),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
            FilledButton(
              key: const Key('wipe_ok'),
              style: FilledButton.styleFrom(backgroundColor: SignalColors.sell),
              onPressed: c.text == 'DELETE ALL MY DATA' ? () => Navigator.pop(ctx, true) : null,
              child: Text(app.t('delete')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await runWithFeedback(context, () async {
      await app.stopBackground();
      await app.engine.wipe(includeBackups: includeBackups);
      await app.refresh();
    }, successKey: 'wiped');
    await _loadBackups();
  }

  Widget _header(String key) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(app.t(key), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      );

  /// On a phone the settings live on the computer; the phone shows the connection and can unpair.
  Widget _companionSettings(AppState app) {
    final c = app.companion!;
    return Scaffold(
      appBar: AppBar(title: Text(app.t('settings'))),
      body: ListView(children: [
        _header('companion_section'),
        ListTile(
          key: const Key('app_build'),
          dense: true,
          leading: const Icon(Icons.tag),
          title: Text(app.t('app_build')),
          subtitle: Text(appBuild),
        ),
        ListTile(
          leading: Icon(app.connected ? Icons.link : Icons.link_off,
              color: app.connected ? SignalColors.buy : SignalColors.sell),
          title: Text(app.t(app.connected ? 'companion_connected' : 'companion_unreachable')),
          subtitle: Text('${c.host}:${c.port}  ·  TLS'),
        ),
        ListTile(leading: const Icon(Icons.info_outline), title: Text(app.t('companion_settings_on_computer'))),
        ListTile(leading: const Icon(Icons.pan_tool_outlined), title: Text(app.t('trading_mode')), subtitle: Text(app.t('manual_only'))),
        if (app.onSwitchMode != null)
          ListTile(
            key: const Key('btn_switch_to_local'),
            leading: const Icon(Icons.smartphone),
            title: Text(app.t('mode_switch_to_local')),
            subtitle: Text(app.t('mode_local_hint')),
            onTap: () => app.onSwitchMode!(),
          ),
        ListTile(
          key: const Key('btn_unpair'),
          leading: const Icon(Icons.link_off, color: SignalColors.sell),
          title: Text(app.t('companion_unpair')),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(app.t('companion_unpair')),
                content: Text(app.t('companion_unpair_hint')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
                  FilledButton(key: const Key('confirm_unpair'), onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('companion_unpair'))),
                ],
              ),
            );
            if (ok == true) await app.onUnpair?.call();
          },
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final indicators = (s['indicators'] as Map?)?.cast<String, dynamic>() ?? const {};
    final secs = app.t('seconds');
    if (app.isCompanion) return _companionSettings(app);
    return Scaffold(
      appBar: AppBar(title: Text(app.t('settings'))),
      body: ListView(children: [
        _header('trading_section'),
        ListTile(leading: const Icon(Icons.pan_tool_outlined), title: Text(app.t('trading_mode')), subtitle: Text(app.t('manual_only'))),
        _dropdown<int>('candle_timeframe_sec', app.t('candle_tf'), _timeframes, _tfLabel),
        if ((s['candle_timeframe_sec'] as int? ?? 30) < 60)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(app.t('tf_warning'), style: const TextStyle(fontSize: 12, color: SignalColors.wait)),
          ),
        _dropdown<int>('trade_duration_min_sec', app.t('min_duration'), _durations, (v) => '$v$secs'),
        _dropdown<int>('trade_duration_max_sec', app.t('max_duration'), _durations, (v) => '$v$secs'),
        _dropdown<int>('signal_cooldown_sec', app.t('cooldown'), _cooldowns, (v) => '$v$secs'),
        SwitchListTile(
          key: const Key('sw_pattern_signals'),
          title: Text(app.t('pattern_signals')),
          subtitle: Text(app.t('pattern_signals_hint'), style: const TextStyle(fontSize: 12)),
          value: s['pattern_signals'] != false,
          onChanged: (v) => _set('pattern_signals', v),
        ),
        SwitchListTile(
          key: const Key('sw_strategy_only'),
          title: Text(app.t('strategy_only')),
          subtitle: Text(app.t('strategy_only_hint'), style: const TextStyle(fontSize: 12)),
          value: s['strategy_only_signals'] == true,
          onChanged: (v) => _set('strategy_only_signals', v),
        ),
        if (s['strategy_only_signals'] != true)
          _dropdown<int>('min_confluence_factors', app.t('min_factors'), const [2, 3, 4, 5, 6], (v) => '$v'),
        _slider('min_confidence_to_signal', app.t('min_conf'), 0.5, 0.95, 9),
        _slider('min_data_quality_to_signal', app.t('min_quality'), 0.3, 1.0, 14),
        SwitchListTile(
          key: const Key('sw_continuous'),
          title: Text(app.t('continuous')),
          value: s['continuous_analysis'] == true,
          onChanged: (v) => _set('continuous_analysis', v),
        ),
        _dropdown<int>('chart_max_side', app.t('chart_max_side'), const [800, 1024, 1280, 1600, 1920, 0],
            (v) => v == 0 ? app.t('chart_original') : '$v px'),
        _dropdown<int>('chart_max_candles', app.t('chart_max_candles'), const [60, 80, 100, 150, 200, 0],
            (v) => v == 0 ? app.t('chart_all_candles') : '$v'),
        _header('indicators_section'),
        ..._indicators.map((name) => SwitchListTile(
              key: Key('ind_$name'),
              dense: true,
              title: Text(app.t('ind_$name')),
              value: indicators[name] != false,
              onChanged: (v) => runWithFeedback(context, () => app.updateSettings({'indicators': {name: v}})),
            )),
        _header('ui_section'),
        ListTile(
          title: Text(app.t('language')),
          trailing: SegmentedButton<String>(
            key: const Key('seg_language'),
            segments: const [ButtonSegment(value: 'ar', label: Text('العربية')), ButtonSegment(value: 'en', label: Text('English'))],
            selected: {app.lang},
            onSelectionChanged: (v) => _set('language', v.first),
          ),
        ),
        ListTile(
          title: Text(app.t('theme')),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SegmentedButton<String>(
              key: const Key('seg_theme'),
              segments: [
                ButtonSegment(value: 'system', label: Text(app.t('theme_system'))),
                ButtonSegment(value: 'dark', label: Text(app.t('theme_dark'))),
                ButtonSegment(value: 'light', label: Text(app.t('theme_light'))),
              ],
              selected: {(s['theme'] as String?) ?? 'system'},
              onSelectionChanged: (v) => _set('theme', v.first),
            ),
          ),
        ),
        if (app.window.isDesktop) ...[
          SwitchListTile(
            title: Text(app.t('always_on_top')),
            value: s['panel_always_on_top'] != false,
            onChanged: (v) => _set('panel_always_on_top', v),
          ),
          _slider('panel_opacity', app.t('opacity'), 0.3, 1.0, 14),
        ],
        _header('privacy_section'),
        SwitchListTile(
          key: const Key('sw_screen'),
          title: Text(app.t('screen_permission')),
          subtitle: Text(app.t('screen_permission_desc')),
          value: s['screen_capture_allowed'] == true,
          onChanged: _togglePermission,
        ),
        if (s['screen_capture_allowed'] == true) ...[
          _header('capture_section'),
          _dropdown<int>('capture_interval_sec', app.t('capture_interval'), const [2, 3, 5, 10, 15, 30, 60], (v) => '$v$secs'),
          _RegionEditor(
            region: (s['capture_region'] as Map?)?.cast<String, dynamic>(),
            app: app,
            onChanged: (r) => _set('capture_region', r ?? 'null'),
          ),
        ],
        SwitchListTile(
          title: Text(app.t('external_sources')),
          value: s['external_data_sources_allowed'] == true,
          onChanged: (v) => _set('external_data_sources_allowed', v),
        ),
        _header('installation_section'),
        ListTile(
          key: const Key('app_build'),
          dense: true,
          leading: const Icon(Icons.tag),
          title: Text(app.t('app_build')),
          subtitle: Text(appBuild),
        ),
                for (final cap in ['ocr', 'speech_to_text', 'ffmpeg', 'screen_capture'])
          ListTile(
            key: Key('cap_$cap'),
            dense: true,
            leading: Icon(app.capabilities[cap] == true ? Icons.check_circle : Icons.remove_circle_outline,
                color: app.capabilities[cap] == true ? SignalColors.buy : SignalColors.wait),
            title: Text(app.t('cap_$cap')),
            subtitle: cap == 'ocr' && app.capabilities['ocr_languages'] is List
                ? Text((app.capabilities['ocr_languages'] as List).join(', '))
                : null,
          ),
        ListTile(
          dense: true,
          title: Text(app.t('stt_model_path')),
          subtitle: Text('${s['stt_model_path'] ?? '—'}'),
          trailing: IconButton(
            key: const Key('edit_stt_path'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final c = TextEditingController(text: s['stt_model_path'] as String? ?? '');
              final v = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(app.t('stt_model_path')),
                  content: TextField(key: const Key('stt_path_field'), controller: c),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: Text(app.t('cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(app.t('save'))),
                  ],
                ),
              );
              if (v != null) {
                await _set('stt_model_path', v.isEmpty ? 'null' : v);
                await app.refresh();
              }
            },
          ),
        ),
        if (app.isOnDevice) ...[
          _header('engine_mode_section'),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text(app.t('mode_local')),
            subtitle: Text(app.t('mode_local_hint')),
          ),
          if (app.onSwitchMode != null)
            ListTile(
              key: const Key('btn_switch_to_computer'),
              leading: const Icon(Icons.computer),
              title: Text(app.t('mode_switch_to_computer')),
              onTap: () => app.onSwitchMode!(),
            ),
        ],
        if (app.has('companion')) ...[
          _header('companion_section'),
          const CompanionDevicesSection(),
        ],
        if (app.has('backups')) ...[
          _header('backup_section'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(key: const Key('btn_backup'), onPressed: _createBackup, icon: const Icon(Icons.lock_outline), label: Text(app.t('create_backup'))),
              OutlinedButton.icon(key: const Key('btn_restore'), onPressed: _restore, icon: const Icon(Icons.restore), label: Text(app.t('restore_backup'))),
            ]),
          ),
        ],
        if (app.has('backups'))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(app.t('backup_copy_hint'), style: Theme.of(context).textTheme.bodySmall),
          ),
        ..._backups.map((b) => ListTile(
              dense: true,
              leading: const Icon(Icons.archive_outlined),
              title: Text('${b['name']}'),
              subtitle: Text(fmtBytes(b['size_bytes'] as num?)),
              trailing: IconButton(
                key: Key('save_backup_${b['name']}'),
                tooltip: app.t('backup_save_copy'),
                icon: const Icon(Icons.save_alt),
                onPressed: () async {
                  final name = b['name'] as String;
                  List<int>? bytes;
                  if (!await runWithFeedback(context, () async => bytes = await app.engine.backupBytes(name))) return;
                  final saved = await widget.saveFile(name, bytes!); // false = the user cancelled: nothing to say
                  if (saved && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t('saved'))));
                  }
                },
              ),
            )),
        _header('danger_section'),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: Text(app.t('reset_settings')),
          onTap: () => runWithFeedback(context, app.resetSettings, successKey: 'saved'),
        ),
        ListTile(
          key: const Key('btn_wipe'),
          leading: const Icon(Icons.delete_forever, color: SignalColors.sell),
          title: Text(app.t('wipe'), style: const TextStyle(color: SignalColors.sell)),
          onTap: _wipe,
        ),
        const SizedBox(height: 32),
      ]),
    );
  }
}


/// Full screen, or a custom rectangle in screen pixels.
class _RegionEditor extends StatefulWidget {
  const _RegionEditor({required this.region, required this.app, required this.onChanged});
  final Map<String, dynamic>? region;
  final AppState app;
  final ValueChanged<Map<String, int>?> onChanged;
  @override
  State<_RegionEditor> createState() => _RegionEditorState();
}

class _RegionEditorState extends State<_RegionEditor> {
  static const _keys = ['left', 'top', 'width', 'height'];
  late final Map<String, TextEditingController> _c = {
    for (final k in _keys) k: TextEditingController(text: '${widget.region?[k] ?? (k == 'width' ? 1000 : k == 'height' ? 600 : 0)}')
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, int>? _parsed() {
    final m = {for (final k in _keys) k: int.tryParse(_c[k]!.text)};
    if (m.values.any((v) => v == null)) return null;
    return m.cast<String, int>();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final custom = widget.region != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(app.t('capture_region')),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          key: const Key('seg_region'),
          segments: [
            ButtonSegment(value: false, label: Text(app.t('full_screen'))),
            ButtonSegment(value: true, label: Text(app.t('custom_region'))),
          ],
          selected: {custom},
          onSelectionChanged: (v) => widget.onChanged(v.first ? _parsed() : null),
        ),
        if (custom) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in _keys)
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('region_$k'),
                  controller: _c[k],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: app.t('region_$k')),
                  onSubmitted: (_) {
                    final r = _parsed();
                    if (r != null) widget.onChanged(r);
                  },
                ),
              ),
          ]),
        ],
      ]),
    );
  }
}
