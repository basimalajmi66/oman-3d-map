/// One-tap quick start: real prices → starter strategies (drafts) → historical test of each → honest results.
/// Approval stays a separate, explicit user action for every strategy.
library;

import 'dart:convert';

import '../core/engine_api.dart';
import 'market_data.dart';
import 'starter_strategies.dart';

enum QuickStartStage { downloading, importing, strategies, testing, done }

class StrategyOutcome {
  StrategyOutcome(this.strategyId, this.name, this.idea, this.result, {this.durationSec = 120});
  final int strategyId;
  final int durationSec; // the tested trade duration
  final String name, idea;
  final Json result; // backtest result: qualifies, gate_reasons, out_of_sample, …
  bool get qualifies => result['qualifies'] == true;
  Json get oos => (result['out_of_sample'] as Map).cast<String, dynamic>();
}

class QuickStartResult {
  QuickStartResult(this.dataset, this.outcomes);
  final Json dataset;
  final List<StrategyOutcome> outcomes;
}

/// Sub-minute candles from Binance come from 1-second klines: keep the download reasonable.
int defaultDays(MarketAsset a, int timeframeSec) => a.source == 'binance' && timeframeSec < 60 ? 3 : 14;

Future<QuickStartResult> runQuickStart(
  EngineApi api,
  MarketDataClient data,
  MarketAsset asset,
  int timeframeSec, {
  double payout = 0.85,
  int? days,
  String lang = 'ar',
  void Function(QuickStartStage stage, double progress)? onStage,
}) async {
  final d = days ?? defaultDays(asset, timeframeSec);
  onStage?.call(QuickStartStage.downloading, 0);
  final csv = await data.download(asset, timeframeSec, days: d, onProgress: (p) => onStage?.call(QuickStartStage.downloading, p));

  onStage?.call(QuickStartStage.importing, 0);
  final bytes = utf8.encode(csv);
  final source = asset.source == 'dukascopy' ? 'Dukascopy' : 'Binance';
  final dataset = await api.importDataset(
      UploadFile(name: '${asset.symbol}.csv', length: bytes.length, openRead: () => Stream.value(bytes)),
      name: '${asset.symbol} ${timeframeSec}s — $source, $d days', asset: asset.symbol);

  onStage?.call(QuickStartStage.strategies, 0);
  final existing = {for (final s in await api.listStrategies()) s['name']: s};
  final ids = <(StarterStrategy, int)>[];
  for (final st in starterStrategies) {
    final have = existing[st.name];
    if (have != null) {
      ids.add((st, have['id'] as int)); // keep the user's copy (and its approval status) — just test it again
    } else {
      final created = await api.createStrategy(st.name, st.definition, description: '${lang == 'ar' ? st.ar : st.en}\n\n$starterSource');
      ids.add((st, created['id'] as int));
    }
  }

  final outcomes = <StrategyOutcome>[];
  for (var i = 0; i < ids.length; i++) {
    onStage?.call(QuickStartStage.testing, i / ids.length);
    final (st, id) = ids[i];
    final r = await api.backtest(id, dataset['id'] as int, payout: payout);
    outcomes.add(StrategyOutcome(id, st.name, lang == 'ar' ? st.ar : st.en, r, durationSec: st.definition['duration_sec'] as int));
  }
  outcomes.sort((a, b) {
    if (a.qualifies != b.qualifies) return a.qualifies ? -1 : 1;
    final ea = (a.oos['expectancy_per_trade'] as num?) ?? -9, eb = (b.oos['expectancy_per_trade'] as num?) ?? -9;
    return eb.compareTo(ea);
  });
  onStage?.call(QuickStartStage.done, 1);
  return QuickStartResult(dataset, outcomes);
}
