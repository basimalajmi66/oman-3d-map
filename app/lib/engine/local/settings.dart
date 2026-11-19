/// User settings with validation and safe defaults (port of core/settings_model.py + settings_service.py).
library;

import 'dart:convert';

import 'db.dart';

const indicatorNames = [
  'price_action', 'candlesticks', 'support_resistance', 'trend', 'supply_demand', 'liquidity_zones', //
  'moving_averages', 'rsi', 'macd', 'bollinger_bands', 'atr', 'volume', 'momentum', 'volatility', 'chart_patterns',
];
const allowedTimeframes = [5, 10, 15, 30, 60, 120, 180, 300, 900, 1800, 3600, 14400, 86400];
const allowedChartMaxSide = [0, 800, 1024, 1280, 1600, 1920]; // 0 = original size
const allowedChartMaxCandles = [0, 60, 80, 100, 150, 200]; // 0 = all; strategies need 50+ closed candles

/// A setting that does not validate (the API reports it as 422, like pydantic).
class SettingsError implements Exception {
  SettingsError(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, dynamic> defaultSettings() => {
      'candle_timeframe_sec': 30,
      'trade_duration_min_sec': 60,
      'trade_duration_max_sec': 180,
      'trading_mode': 'manual', // the only mode: the system never executes trades
      'continuous_analysis': false,
      'min_confidence_to_signal': 0.65,
      'min_data_quality_to_signal': 0.6,
      'min_confluence_factors': 3,
      'signal_cooldown_sec': 30,
      'indicators': {for (final n in indicatorNames) n: true},
      'language': 'ar',
      'theme': 'system',
      'panel_always_on_top': true,
      'panel_opacity': 0.95,
      'screen_capture_allowed': false,
      'capture_region': null,
      'capture_interval_sec': 5,
      'chart_max_side': 1280,
      'chart_max_candles': 100,
      'external_data_sources_allowed': false,
      'stt_model_path': null,
      'companion_enabled': false,
      'companion_port': 8766,
    };

int _int(Map s, String k, int lo, int hi) {
  final v = s[k];
  if (v is! int || v is bool) throw SettingsError('$k must be an integer');
  if (v < lo || v > hi) throw SettingsError('$k must be between $lo and $hi');
  return v;
}

double _float(Map s, String k, double lo, double hi) {
  final v = s[k];
  if (v is! num) throw SettingsError('$k must be a number');
  if (v < lo || v > hi) throw SettingsError('$k must be between $lo and $hi');
  return v.toDouble();
}

bool _bool(Map s, String k) {
  final v = s[k];
  if (v is! bool) throw SettingsError('$k must be true or false');
  return v;
}

String _choice(Map s, String k, List<String> options) {
  final v = s[k];
  if (v is! String || !options.contains(v)) throw SettingsError('$k must be one of $options');
  return v;
}

/// Validate a complete settings map; returns a normalised copy. Unknown keys are refused.
Map<String, dynamic> validateSettings(Map input) {
  final s = Map<String, dynamic>.from(input);
  final defaults = defaultSettings();
  final extra = s.keys.where((k) => !defaults.containsKey(k)).toList();
  if (extra.isNotEmpty) throw SettingsError('unknown settings: $extra');
  final tf = _int(s, 'candle_timeframe_sec', 1, 86400);
  if (!allowedTimeframes.contains(tf)) throw SettingsError('candle_timeframe_sec must be one of $allowedTimeframes');
  final dMin = _int(s, 'trade_duration_min_sec', 30, 3600), dMax = _int(s, 'trade_duration_max_sec', 30, 3600);
  if (dMin > dMax) throw SettingsError('trade_duration_min_sec must be <= trade_duration_max_sec');
  if (s['trading_mode'] != 'manual') throw SettingsError("trading_mode must be 'manual'");
  _bool(s, 'continuous_analysis');
  s['min_confidence_to_signal'] = _float(s, 'min_confidence_to_signal', 0.5, 0.95);
  s['min_data_quality_to_signal'] = _float(s, 'min_data_quality_to_signal', 0.3, 1.0);
  _int(s, 'min_confluence_factors', 2, 10);
  _int(s, 'signal_cooldown_sec', 0, 3600);
  final ind = s['indicators'];
  if (ind is! Map) throw SettingsError('indicators must be a map');
  final unknown = ind.keys.where((k) => !indicatorNames.contains(k)).toList()..sort();
  if (unknown.isNotEmpty) throw SettingsError('unknown indicators: $unknown');
  final full = {for (final n in indicatorNames) n: ind[n] ?? true};
  if (full.values.any((v) => v is! bool)) throw SettingsError('indicator values must be true or false');
  if (full.values.where((v) => v == true).length < 2) throw SettingsError('at least two analysis factors must stay enabled');
  s['indicators'] = full;
  _choice(s, 'language', const ['ar', 'en']);
  _choice(s, 'theme', const ['system', 'dark', 'light']);
  _bool(s, 'panel_always_on_top');
  s['panel_opacity'] = _float(s, 'panel_opacity', 0.3, 1.0);
  _bool(s, 'screen_capture_allowed');
  final region = s['capture_region'];
  if (region != null) {
    if (region is! Map || region.keys.toSet().difference({'left', 'top', 'width', 'height'}).isNotEmpty || region.length != 4) {
      throw SettingsError('capture_region needs exactly [height, left, top, width]');
    }
    if ((region['width'] as num) < 200 || (region['height'] as num) < 150) {
      throw SettingsError('capture_region is too small to contain a readable chart (min 200x150)');
    }
  }
  _int(s, 'capture_interval_sec', 2, 60);
  if (!allowedChartMaxSide.contains(_int(s, 'chart_max_side', 0, 10000))) {
    throw SettingsError('chart_max_side must be one of $allowedChartMaxSide');
  }
  if (!allowedChartMaxCandles.contains(_int(s, 'chart_max_candles', 0, 10000))) {
    throw SettingsError('chart_max_candles must be one of $allowedChartMaxCandles');
  }
  _bool(s, 'external_data_sources_allowed');
  if (s['stt_model_path'] != null && s['stt_model_path'] is! String) throw SettingsError('stt_model_path must be text');
  _bool(s, 'companion_enabled');
  _int(s, 'companion_port', 1024, 65535);
  return s;
}

class SettingsStore {
  SettingsStore(this.db);
  final LocalDb db;
  static const _key = 'user_settings';

  Map<String, dynamic> get() {
    final row = db.session((d) => d.select('SELECT value_json FROM settings WHERE key=?', [_key]));
    if (row.isEmpty) return defaultSettings();
    final stored = (jsonDecode(row.first['value_json'] as String) as Map).cast<String, dynamic>();
    try {
      return validateSettings({...defaultSettings(), ...stored});
    } on SettingsError {
      // stored settings from another version: keep the valid keys only
      final base = defaultSettings();
      for (final e in stored.entries) {
        if (!base.containsKey(e.key)) continue;
        try {
          validateSettings({...base, e.key: e.value});
          base[e.key] = e.value;
        } on SettingsError {
          // keep the default for this key
        }
      }
      return validateSettings(base);
    }
  }

  Map<String, dynamic> update(Map<String, dynamic> patch) {
    final current = get();
    var p = patch;
    if (patch['indicators'] is Map) {
      p = {...patch, 'indicators': {...(current['indicators'] as Map), ...(patch['indicators'] as Map)}};
    }
    final merged = validateSettings({...current, ...p});
    _save(merged, (patch.keys.toList()..sort()));
    return merged;
  }

  Map<String, dynamic> reset() {
    final s = defaultSettings();
    _save(s, ['*reset*']);
    return s;
  }

  void _save(Map<String, dynamic> s, List<String> changed) => db.session((d) {
        d.execute(
            'INSERT INTO settings(key, value_json, updated_at) VALUES (?,?,?) '
            'ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at',
            [_key, jsonEncode(s), utcnow()]);
        audit(d, 'user', 'settings.update', {'keys': changed});
      });
}
