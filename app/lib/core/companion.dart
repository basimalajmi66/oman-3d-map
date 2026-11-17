import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_api.dart';
import 'engine_host.dart';
import 'http_engine_api.dart';

/// What the QR code on the computer contains: `uata://pair?h=<ip>&p=<port>&fp=<sha256>&c=<code>`.
class PairingLink {
  PairingLink({required this.host, required this.port, required this.fingerprint, required this.code});
  final String host;
  final int port;
  final String fingerprint; // lowercase hex SHA-256 of the engine's certificate (DER)
  final String code;

  /// Returns null for anything that is not a complete pairing link.
  static PairingLink? tryParse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'uata' || u.host != 'pair') return null;
    final q = u.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final fp = (q['fp'] ?? '').toLowerCase();
    if ((q['h'] ?? '').isEmpty || port == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp) ||
        (q['c'] ?? '').isEmpty) {
      return null;
    }
    return PairingLink(host: q['h']!, port: port, fingerprint: fp, code: q['c']!);
  }
}

/// A completed pairing, kept in the app's private storage.
class CompanionPairing {
  CompanionPairing({required this.host, required this.port, required this.fingerprint, required this.token});
  final String host;
  final int port;
  final String fingerprint;
  final String token;

  Uri get baseUrl => Uri(scheme: 'https', host: host, port: port);

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'fingerprint': fingerprint, 'token': token};
  static CompanionPairing fromJson(Map<String, dynamic> j) => CompanionPairing(
      host: j['host'] as String, port: j['port'] as int, fingerprint: j['fingerprint'] as String,
      token: j['token'] as String);
}

String certificateFingerprint(X509Certificate cert) => sha256.convert(cert.der).toString();

/// HTTPS client that trusts exactly one certificate: the one whose fingerprint came
/// in the QR code. Any other certificate (even a "valid" public one) is refused.
http.Client pinnedClient(String fingerprint, {Duration connectTimeout = const Duration(seconds: 8)}) {
  final io = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = connectTimeout
    ..badCertificateCallback = (cert, host, port) => certificateFingerprint(cert) == fingerprint.toLowerCase();
  return IOClient(io);
}

class CompanionStore {
  static const _key = 'uata.companion.pairing';

  static Future<CompanionPairing?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      return CompanionPairing.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CompanionPairing p) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(p.toJson()));

  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}

/// Exchange the one-time code for this device's token (over the pinned TLS connection).
Future<CompanionPairing> pairWithComputer(PairingLink link, String deviceName, {http.Client? client}) async {
  final c = client ?? pinnedClient(link.fingerprint);
  try {
    final r = await c
        .post(Uri(scheme: 'https', host: link.host, port: link.port, path: '/companion/pair'),
            headers: {'content-type': 'application/json'}, body: jsonEncode({'code': link.code, 'name': deviceName}))
        .timeout(const Duration(seconds: 15));
    final body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200) {
      throw EngineException(r.statusCode, body is Map ? '${body['detail']}' : 'pairing failed');
    }
    return CompanionPairing(
        host: link.host, port: link.port, fingerprint: link.fingerprint, token: (body as Map)['token'] as String);
  } on EngineException {
    rethrow;
  } catch (e) {
    throw EngineException(0, 'computer unreachable: $e');
  } finally {
    if (client == null) c.close();
  }
}

/// Phone / tablet: the engine is on the user's computer.
class RemoteEngineHost implements EngineHost {
  RemoteEngineHost(this.pairing);
  final CompanionPairing pairing;

  @override
  String get kind => 'remote';

  @override
  Future<EngineApi> connect() async => HttpEngineApi(
        baseUrl: pairing.baseUrl,
        tokenProvider: () async => pairing.token,
        authHeader: 'X-UATA-Device',
        client: pinnedClient(pairing.fingerprint),
        timeout: const Duration(seconds: 30),
      );

  @override
  void dispose() {}
}
