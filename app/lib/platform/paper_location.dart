import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where paper-trading sessions live: inside the engine's files, so they travel in encrypted backups and are
/// removed by "delete all data". Sessions from older versions (next to the engine) are moved once.
Future<String> paperDirectory() async {
  final base = (await getApplicationSupportDirectory()).path;
  final dir = Directory('$base/uata/files/paper');
  final old = Directory('$base/paper');
  if (old.existsSync() && !dir.existsSync()) {
    dir.parent.createSync(recursive: true);
    try {
      old.renameSync(dir.path);
    } on FileSystemException {
      // keep the old place if the move is not possible; nothing is lost
      return old.path;
    }
  }
  return dir.path;
}
