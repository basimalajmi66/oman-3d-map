import 'package:flutter/services.dart';

/// Pictures of the phone's screen, after the user accepted Android's screen-sharing prompt (visible notification
/// while active). Used only when the user asks for an analysis over the trading app (button or automatic mode).
abstract class ScreenSource {
  Future<bool> start(); // shows Android's prompt the first time; false when the user said no
  Future<Uint8List?> capture(); // PNG of the screen now (null: not running / no frame yet)
  Future<bool> running();
  Future<void> stop();
}

class AndroidScreenSource implements ScreenSource {
  static const _ch = MethodChannel('uata/screen');
  @override
  Future<bool> start() async => await _ch.invokeMethod<bool>('start') ?? false;
  @override
  Future<Uint8List?> capture() => _ch.invokeMethod<Uint8List>('capture');
  @override
  Future<bool> running() async => await _ch.invokeMethod<bool>('running') ?? false;
  @override
  Future<void> stop() => _ch.invokeMethod('stop');
}
