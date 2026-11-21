/// On-device speech recognition for videos: whisper.cpp (whisper_ggml) with the multilingual "tiny" model bundled
/// in the app. The video's sound is converted and recognised on the phone; nothing is uploaded anywhere.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../engine/knowledge/extract.dart' show Cue;

const whisperAsset = 'assets/whisper/ggml-tiny.bin';

/// True when the model is inside this build (it is added by the release build; development builds may lack it).
Future<bool> whisperBundled() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest.listAssets().contains(whisperAsset);
  } catch (_) {
    return false;
  }
}

Future<void> _ensureModel(WhisperController ctrl) async {
  final f = File(await ctrl.getPath(WhisperModel.tiny));
  if (f.existsSync() && f.lengthSync() > 1000000) return;
  final data = await rootBundle.load(whisperAsset);
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.part')..writeAsBytesSync(data.buffer.asUint8List(), flush: true);
  tmp.renameSync(f.path);
}

/// Timed speech of a video file, or null when recognition failed.
Future<List<Cue>?> whisperSpeech(String videoPath) async {
  final ctrl = WhisperController();
  await _ensureModel(ctrl);
  final r = await ctrl.transcribe(
    model: WhisperModel.tiny,
    audioPath: videoPath,
    lang: 'auto',
    withSegments: true,
    suppressNonSpeechTokens: true,
    maxContext: 0, // a misheard phrase must not repeat through a long video
  );
  if (r == null) return null;
  return [
    for (final s in r.transcription.segments ?? const [])
      if (s.text.trim().isNotEmpty) (startMs: s.fromTs.inMilliseconds, endMs: s.toTs.inMilliseconds, text: s.text.trim())
  ];
}
