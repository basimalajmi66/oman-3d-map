/// On-device OCR for chart labels: Tesseract (Tesseract4Android) with the English model bundled in the app.
/// Nothing leaves the phone. The model is copied once from the app's assets to its private storage.
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:tesseract_ocr/ocr_engine_config.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

String? _dataDir;

Future<String> _ensureModel() async {
  if (_dataDir case final d?) return d;
  final base = (await getApplicationSupportDirectory()).path;
  for (final lang in const ['eng', 'ara']) {
    final f = File('$base/ocr/tessdata/$lang.traineddata');
    final asset = await rootBundle.load('assets/tessdata/$lang.traineddata');
    if (!f.existsSync() || f.lengthSync() != asset.lengthInBytes) {
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.part')..writeAsBytesSync(asset.buffer.asUint8List(), flush: true);
      tmp.renameSync(f.path);
    }
  }
  return _dataDir = '$base/ocr';
}

/// [PageOcr] for the phone engine: the text of a whole image (Arabic and English).
Future<String> tesseractText(List<int> image, String ext) async {
  final data = await _ensureModel();
  final f = File('${(await getTemporaryDirectory()).path}/uata_page_${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(image, flush: true);
  try {
    return await TesseractOcr.extractText(f.path,
        config: OCRConfig(language: 'ara+eng', engine: OCREngine.tesseract, tessDataPath: data));
  } finally {
    try {
      f.deleteSync();
    } catch (_) {}
  }
}

/// [LineOcr] for the phone engine.
Future<String> tesseractLine(List<int> png, {required bool digits}) async {
  final data = await _ensureModel();
  final img = File('${(await getTemporaryDirectory()).path}/uata_ocr_${DateTime.now().microsecondsSinceEpoch}.png');
  await img.writeAsBytes(png, flush: true);
  try {
    return await TesseractOcr.extractText(img.path,
        config: OCRConfig(language: 'eng', engine: OCREngine.tesseract, tessDataPath: data));
  } finally {
    try {
      img.deleteSync();
    } catch (_) {}
  }
}
