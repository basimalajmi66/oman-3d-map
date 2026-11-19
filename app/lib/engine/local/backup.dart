/// Encrypted backup / restore on the phone — the SAME `.uatabak` format as the computer engine
/// (backend/uata/services/backup_service.py), so a backup moves between phone and computer:
///
///     magic "UATABAK1" | header_len uint32 BE | header JSON {kdf: scrypt, n, r, p, salt, nonce_prefix, chunk}
///     chunks: [len uint32 BE][AES-256-GCM ciphertext+tag] ...
///
/// nonce = nonce_prefix(8) || counter uint32 BE; associated data = header || counter uint32 BE || is_last byte,
/// so chunks cannot be reordered, dropped or truncated. Key = scrypt(passphrase). The passphrase is never stored.
/// The plaintext is a ZIP with manifest.json, uata.sqlite3 and files/….
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:pointycastle/export.dart';

const backupMagic = 'UATABAK1';
const backupChunk = 4 * 1024 * 1024;
const scryptN = 32768, scryptR = 8, scryptP = 1;
const minPassphrase = 10;

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _derive(String passphrase, Uint8List salt, int n, int r, int p) {
  final kdf = Scrypt()..init(ScryptParameters(n, r, p, 32, salt));
  return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

GCMBlockCipher _gcm(Uint8List key, Uint8List prefix, int counter, Uint8List header, bool last, bool encrypt) {
  final nonce = Uint8List.fromList([...prefix, ..._u32(counter)]);
  final aad = Uint8List.fromList([...header, ..._u32(counter), last ? 1 : 0]);
  return GCMBlockCipher(AESEngine())..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
}

/// Encrypt file `src` into `dst` (runs in a background isolate: scrypt + AES take a few seconds on a phone).
Future<void> encryptFile(String src, String dst, String passphrase) => Isolate.run(() {
      final salt = _randomBytes(16), prefix = _randomBytes(8);
      final header = utf8.encode(jsonEncode({
        'kdf': 'scrypt', 'n': scryptN, 'r': scryptR, 'p': scryptP, 'salt': _hex(salt), 'nonce_prefix': _hex(prefix),
        'chunk': backupChunk,
      }));
      final key = _derive(passphrase, salt, scryptN, scryptR, scryptP);
      final input = File(src).openSync();
      final out = File(dst).openSync(mode: FileMode.write);
      try {
        out
          ..writeFromSync(ascii.encode(backupMagic))
          ..writeFromSync(_u32(header.length))
          ..writeFromSync(header);
        var counter = 0;
        var current = input.readSync(backupChunk);
        while (true) {
          final next = input.readSync(backupChunk);
          final last = next.isEmpty;
          final ct = _gcm(key, prefix, counter, Uint8List.fromList(header), last, true).process(current);
          out
            ..writeFromSync(_u32(ct.length))
            ..writeFromSync(ct);
          if (last) break;
          current = next;
          counter++;
        }
      } finally {
        input.closeSync();
        out.closeSync();
      }
    });

/// Decrypt `src` into `dst`. Wrong passphrase, tampering and truncation all fail (BackupException).
Future<void> decryptFile(String src, String dst, String passphrase) async {
  final error = await Isolate.run(() {
    final input = File(src).openSync();
    final out = File(dst).openSync(mode: FileMode.write);
    try {
      if (ascii.decode(input.readSync(8), allowInvalid: true) != backupMagic) return 'not a UATA backup file';
      final hl = input.readSync(4);
      if (hl.length < 4) return 'not a UATA backup file';
      final hlen = hl.buffer.asByteData().getUint32(0);
      if (hlen > 4096) return 'corrupt header';
      final header = input.readSync(hlen);
      final Map meta;
      try {
        meta = jsonDecode(utf8.decode(header)) as Map;
      } catch (_) {
        return 'corrupt header';
      }
      if (meta['kdf'] != 'scrypt') return 'unsupported key derivation';
      final key = _derive(passphrase, _unhex(meta['salt'] as String), meta['n'] as int, meta['r'] as int, meta['p'] as int);
      final prefix = _unhex(meta['nonce_prefix'] as String);
      final total = input.lengthSync();
      var counter = 0;
      while (true) {
        final rl = input.readSync(4);
        if (rl.length < 4) return 'backup is truncated';
        final clen = rl.buffer.asByteData().getUint32(0);
        final ct = input.readSync(clen);
        if (ct.length != clen) return 'backup is truncated';
        final last = input.positionSync() == total;
        try {
          out.writeFromSync(_gcm(key, prefix, counter, header, last, false).process(ct));
        } on InvalidCipherTextException {
          return 'wrong passphrase or corrupted backup';
        } on ArgumentError {
          return 'wrong passphrase or corrupted backup';
        }
        if (last) return null;
        counter++;
      }
    } finally {
      input.closeSync();
      out.closeSync();
    }
  });
  if (error != null) {
    File(dst).deleteSync();
    throw BackupException(error);
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// Build the ZIP payload: manifest.json, uata.sqlite3 (a consistent copy) and files/….
Future<int> writePayload(String zipPath, String dbCopy, String filesDir, Map<String, dynamic> manifest) async {
  final files = Directory(filesDir).existsSync()
      ? Directory(filesDir).listSync(recursive: true).whereType<File>().where((f) => !f.uri.pathSegments.last.startsWith('.')).toList()
      : <File>[];
  manifest['file_count'] = files.length;
  await Isolate.run(() async {
    final enc = ZipFileEncoder()..create(zipPath);
    enc.addArchiveFile(ArchiveFile.string('manifest.json', const JsonEncoder.withIndent('  ').convert(manifest)));
    await enc.addFile(File(dbCopy), 'uata.sqlite3'); // asynchronous: must finish before the archive is closed
    for (final f in files) {
      await enc.addFile(f, 'files/${f.path.substring(filesDir.length + 1).replaceAll('\\', '/')}');
    }
    await enc.close();
  });
  return files.length;
}

/// Extract a decrypted payload into `dir`, refusing paths that escape it (zip-slip). Returns the manifest.
Future<Map<String, dynamic>> extractPayload(String zipPath, String dir) async {
  final error = await Isolate.run(() {
    final root = Directory(dir)..createSync(recursive: true);
    final base = root.absolute.path;
    final archive = ZipDecoder().decodeStream(InputFileStream(zipPath));
    for (final entry in archive) {
      final target = File('$base/${entry.name}').absolute;
      final norm = target.uri.normalizePath().toFilePath();
      if (entry.name.contains('..') || !norm.startsWith('$base${Platform.pathSeparator}')) {
        return 'unsafe path in backup: ${entry.name}';
      }
      if (entry.isFile) {
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(entry.content as List<int>);
      }
    }
    return null;
  });
  if (error != null) throw BackupException(error);
  final mf = File('$dir/manifest.json');
  if (!mf.existsSync()) throw BackupException('not a UATA backup (no manifest)');
  final manifest = (jsonDecode(mf.readAsStringSync()) as Map).cast<String, dynamic>();
  if (manifest['format'] != 1) throw BackupException('unsupported backup format');
  return manifest;
}
