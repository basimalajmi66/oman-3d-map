import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/engine_api.dart';

/// A file another app shared with UATA (Android/iOS share sheet).
class SharedItem {
  const SharedItem(this.path);
  final String path;
  String get name => p.basename(path);
  String get ext => p.extension(path).toLowerCase();
  bool get isImage => const {'.png', '.jpg', '.jpeg', '.webp', '.bmp'}.contains(ext);
  bool get isKnowledgeFile => const {
        '.pdf', '.docx', '.xlsx', '.xlsm', '.txt', '.md', '.csv', '.mp4', '.mkv', '.mov', '.avi', '.webm',
      }.contains(ext);
}

/// Where shared items come from. Replaceable in tests.
abstract class ShareSource {
  Future<List<SharedItem>> initial();
  Stream<List<SharedItem>> stream();
  Future<void> reset();
}

class ReceiveSharingIntentSource implements ShareSource {
  static List<SharedItem> _map(List<SharedMediaFile> files) => files.map((f) => SharedItem(f.path)).toList();

  @override
  Future<List<SharedItem>> initial() async => _map(await ReceiveSharingIntent.instance.getInitialMedia());
  @override
  Stream<List<SharedItem>> stream() => ReceiveSharingIntent.instance.getMediaStream().map(_map);
  @override
  Future<void> reset() async => ReceiveSharingIntent.instance.reset();
}

enum ShareOutcomeKind { chartAnalysed, addedToLibrary, duplicate, unsupported, failed }

class ShareOutcome {
  ShareOutcome(this.item, this.kind, {this.result, this.error});
  final SharedItem item;
  final ShareOutcomeKind kind;
  final Json? result;
  final String? error;
}

/// Routes shared files: chart screenshots go to analysis (`input_mode=share`),
/// documents and videos go to the knowledge library (pending your approval).
/// Nothing is uploaded anywhere except the local engine.
class ShareIntake {
  ShareIntake({required this.engine, required this.source, required this.onOutcomes, this.libraryAvailable = true});

  /// False on the phone engine (no knowledge library yet): documents are reported as unsupported.
  bool libraryAvailable;

  /// Replaced when the phone is paired again (a new engine connection).
  EngineApi engine;
  final ShareSource source;
  void Function(List<ShareOutcome>) onOutcomes;
  StreamSubscription<List<SharedItem>>? _sub;

  Future<void> start() async {
    final first = await source.initial();
    if (first.isNotEmpty) {
      onOutcomes(await process(first));
      await source.reset();
    }
    _sub = source.stream().listen((items) async {
      if (items.isEmpty) return;
      onOutcomes(await process(items));
      await source.reset();
    });
  }

  Future<List<ShareOutcome>> process(List<SharedItem> items) async {
    final out = <ShareOutcome>[];
    for (final item in items) {
      if (!item.isImage && (!item.isKnowledgeFile || !libraryAvailable)) {
        out.add(ShareOutcome(item, ShareOutcomeKind.unsupported));
        continue;
      }
      final file = File(item.path);
      try {
        final upload = UploadFile(name: item.name, length: await file.length(), openRead: file.openRead);
        if (item.isImage) {
          out.add(ShareOutcome(item, ShareOutcomeKind.chartAnalysed,
              result: await engine.submitChartImage(upload, inputMode: 'share')));
        } else {
          out.add(ShareOutcome(item, ShareOutcomeKind.addedToLibrary, result: await engine.uploadFile(upload)));
        }
      } on EngineException catch (e) {
        out.add(ShareOutcome(item, e.statusCode == 409 && !item.isImage ? ShareOutcomeKind.duplicate : ShareOutcomeKind.failed,
            error: e.message));
      } on FileSystemException catch (e) {
        out.add(ShareOutcome(item, ShareOutcomeKind.failed, error: e.message));
      }
    }
    return out;
  }

  void dispose() => _sub?.cancel();
}
