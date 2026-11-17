import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Abstraction over the native window so the UI stays testable and portable.
/// Desktop: small frameless always-on-top panel (OS window APIs only — nothing
/// is injected into any trading platform). Mobile/tests: no-op.
abstract class WindowController {
  bool get isDesktop;
  Future<void> setExpanded(bool expanded);
  Future<void> setAlwaysOnTop(bool value);
  Future<void> setOpacity(double value);
  Future<void> minimize();
  Future<void> close();

  static Future<WindowController> create() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final c = DesktopWindowController();
      await c.init();
      return c;
    }
    return NoopWindowController();
  }
}

class NoopWindowController implements WindowController {
  @override
  bool get isDesktop => false;
  @override
  Future<void> setExpanded(bool expanded) async {}
  @override
  Future<void> setAlwaysOnTop(bool value) async {}
  @override
  Future<void> setOpacity(double value) async {}
  @override
  Future<void> minimize() async {}
  @override
  Future<void> close() async {}
}

class DesktopWindowController with WindowListener implements WindowController {
  static const compactSize = Size(340, 520);
  static const expandedSize = Size(1000, 720);
  static const _kX = 'panel_x', _kY = 'panel_y', _kW = 'panel_w', _kH = 'panel_h';

  bool _expanded = false;
  SharedPreferences? _prefs;

  @override
  bool get isDesktop => true;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    _prefs = await SharedPreferences.getInstance();
    final w = _prefs!.getDouble(_kW) ?? compactSize.width;
    final h = _prefs!.getDouble(_kH) ?? compactSize.height;
    const options = WindowOptions(
      title: 'UATA',
      minimumSize: Size(300, 420),
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
      skipTaskbar: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setSize(Size(w, h));
      final x = _prefs!.getDouble(_kX), y = _prefs!.getDouble(_kY);
      if (x != null && y != null) {
        await windowManager.setPosition(Offset(x, y));
      } else {
        await windowManager.setAlignment(Alignment.topRight);
      }
      await windowManager.setResizable(true);
      await windowManager.show();
    });
    windowManager.addListener(this);
  }

  // Remember the compact panel's position and size between launches.
  @override
  void onWindowMoved() => _persist();
  @override
  void onWindowResized() => _persist();

  Future<void> _persist() async {
    if (_expanded) return;
    final b = await windowManager.getBounds();
    await _prefs?.setDouble(_kX, b.left);
    await _prefs?.setDouble(_kY, b.top);
    await _prefs?.setDouble(_kW, b.width);
    await _prefs?.setDouble(_kH, b.height);
  }

  @override
  Future<void> setExpanded(bool expanded) async {
    if (expanded == _expanded) return;
    if (expanded) await _persist();
    _expanded = expanded;
    if (expanded) {
      await windowManager.setSize(expandedSize);
      await windowManager.center();
    } else {
      await windowManager.setSize(Size(_prefs?.getDouble(_kW) ?? compactSize.width,
          _prefs?.getDouble(_kH) ?? compactSize.height));
      final x = _prefs?.getDouble(_kX), y = _prefs?.getDouble(_kY);
      if (x != null && y != null) await windowManager.setPosition(Offset(x, y));
    }
  }

  @override
  Future<void> setAlwaysOnTop(bool value) => windowManager.setAlwaysOnTop(value);
  @override
  Future<void> setOpacity(double value) => windowManager.setOpacity(value);
  @override
  Future<void> minimize() => windowManager.minimize();
  @override
  Future<void> close() => windowManager.close();
}
