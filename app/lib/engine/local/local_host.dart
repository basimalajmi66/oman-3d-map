import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../core/engine_api.dart';
import '../../core/engine_host.dart';
import '../../platform/tesseract_line_ocr.dart';
import 'local_engine_api.dart';

/// Phone / tablet on its own: the engine runs inside the app, data in the app's private storage.
class LocalEngineHost implements EngineHost {
  LocalEngine? _engine;

  @override
  String get kind => 'local';

  @override
  Future<EngineApi> connect() async {
    final dir = await getApplicationSupportDirectory();
    _engine = await LocalEngine.open('${dir.path}/uata', (v) => rootBundle.loadString('assets/schema/schema_v$v.sql'),
        ocr: Platform.isAndroid ? (png, {required digits}) => tesseractLine(png, digits: digits) : null);
    return LocalEngineApi(_engine!);
  }

  @override
  void dispose() {
    _engine?.close();
    _engine = null;
  }
}
