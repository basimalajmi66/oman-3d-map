import 'package:flutter_test/flutter_test.dart';
import 'package:uata_app/data/paper_trading.dart';
import 'package:uata_app/platform/background_mode.dart';

void main() {
  test('alert texts: side, asset, duration, the paper record and "the decision is yours"', () {
    final s = PaperSession(id: 'x', asset: 'BTCUSDT', timeframeSec: 60, payout: 0.85, strategyIds: [3], startedAt: 0, trades: {
      '3:1': {'strategy_id': 3, 'outcome': 'win'},
      '3:2': {'strategy_id': 3, 'outcome': 'loss'},
      '3:3': {'strategy_id': 3, 'outcome': 'win'},
      '4:1': {'strategy_id': 4, 'outcome': 'loss'},
    });
    final e = PaperEvent.signal(s, 3, 'RSI bounce', 'BUY', 120, 1000, 7);
    expect(signalTitle('ar', e), '🟢 إشارة شراء · بيتكوين · 2 د');
    expect(signalTitle('en', PaperEvent.signal(s, 3, 'x', 'SELL', 90, 1, 1)), '🔴 SELL signal · Bitcoin · 90 s');
    final body = signalBody('ar', e);
    expect(body, contains('RSI bounce'));
    expect(body, contains('3 صفقة، فوز 2 وخسارة 1'));
    expect(body, contains('ليست دليلاً على ربح'));
    expect(body, contains('قبل 7 ث'));
    expect(body, contains('القرار والتنفيذ لك'));
    expect(signalBody('en', PaperEvent.signal(s, 9, 'new', 'BUY', 60, 1, 2)), contains('no paper results yet'));
  });
}
