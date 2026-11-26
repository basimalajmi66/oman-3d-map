import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../core/engine_api.dart';

/// Android floating window (drawn over other apps) — requires the user to grant
/// "Display over other apps" (SYSTEM_ALERT_WINDOW). It only *displays* the
/// current recommendation; it cannot interact with other apps or trade.
abstract class OverlayController {
  bool get supported;
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  Future<bool> isActive();
  Future<void> show();
  Future<void> hide();
  Future<void> push(Json payload);
}

class NoOverlay implements OverlayController {
  @override
  bool get supported => false;
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<bool> isActive() async => false;
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> push(Json payload) async {}
}

class AndroidOverlayController implements OverlayController {
  @override
  bool get supported => true;
  @override
  Future<bool> hasPermission() => FlutterOverlayWindow.isPermissionGranted();
  @override
  Future<bool> requestPermission() async => await FlutterOverlayWindow.requestPermission() ?? false;
  @override
  Future<bool> isActive() => FlutterOverlayWindow.isActive();

  @override
  Future<void> show() => FlutterOverlayWindow.showOverlay(
        // pixels: a low horizontal strip (the tablet screen is about 2000 × 1250 px), dragged up or down;
        // a narrower screen gets the stacked layout automatically
        height: 340,
        width: 1700,
        alignment: OverlayAlignment.topRight,
        enableDrag: true,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: 'UATA',
        overlayContent: 'Floating panel active — display only, no trading',
        positionGravity: PositionGravity.none,
      );

  @override
  Future<void> hide() async => FlutterOverlayWindow.closeOverlay();

  @override
  Future<void> push(Json payload) async {
    // a direct port first: the plugin's message channel is redirected whenever another engine (floating window,
    // background service) starts, and then messages go astray
    final port = IsolateNameServer.lookupPortByName(overlayDataPort);
    if (port != null) {
      port.send(payload);
      return;
    }
    if (await FlutterOverlayWindow.isActive()) await FlutterOverlayWindow.shareData(payload);
  }
}

/// The compact payload the overlay renders (it runs in a separate Flutter engine).
Json overlayPayload({required String lang, required String state, required Json recommendation, Object? timeframe}) => {
      'lang': lang,
      'state': state,
      'signal': recommendation['signal'] ?? 'WAIT',
      'reason_code': recommendation['reason_code'],
      'confidence': recommendation['confidence'],
      'confidence_calibrated': recommendation['confidence_calibrated'] == true,
      'duration_sec': recommendation['duration_sec'],
      'timeframe_sec': timeframe,
    };


/// Port names shared by the app and its floating window (separate engines in the same process, same Dart VM).
const overlayDataPort = 'uata_overlay_data'; // app → window
const overlayCommandPort = 'uata_overlay_cmd'; // window → app

/// Registers a fresh port under `name` (replacing a stale one) and returns it.
ReceivePort registerPort(String name) {
  final p = ReceivePort();
  IsolateNameServer.removePortNameMapping(name);
  IsolateNameServer.registerPortWithName(p.sendPort, name);
  return p;
}

/// Window → app: through the direct port when the app is listening, else through the plugin.
void sendToApp(Json message) {
  final port = IsolateNameServer.lookupPortByName(overlayCommandPort);
  if (port != null) {
    port.send(message);
  } else {
    FlutterOverlayWindow.shareData(message);
  }
}
