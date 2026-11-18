import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_api.dart';
import 'engine_host.dart';
import 'http_engine_api.dart';

/// What the QR code on the computer contains: `uata://pair?h=<ip>&p=<port>&fp=<sha256>&c=<code>`.
class PairingLink {
  PairingLink({
    required String host,
    List<String>? hosts,
    required this.port,
    required this.fingerprint,
    required this.code,
  }) : hosts = hosts ?? [host];

  /// Every address of the computer (Wi-Fi, Ethernet, ...), tried in turn.
  final List<String> hosts;
  String get host => hosts.first;
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
    final hosts = (q['h'] ?? '').split(',').map((h) => h.trim()).where((h) => h.isNotEmpty).toList();
    if (hosts.isEmpty || port == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp) || (q['c'] ?? '').isEmpty) {
      return null;
    }
    return PairingLink(host: hosts.first, hosts: hosts, port: port, fingerprint: fp, code: q['c']!);
  }
}

/// A completed pairing, kept in the app's private storage.
class CompanionPairing {
  CompanionPairing({
    required this.host,
    List<String>? hosts,
    required this.port,
    required this.fingerprint,
    required this.token,
  }) : hosts = hosts ?? [host];
  final String host;

  /// All known addresses of the computer, [host] (the one that answered last) first.
  final List<String> hosts;
  final int port;
  final String fingerprint;
  final String token;

  Uri get baseUrl => urlFor(host);
  Uri urlFor(String h) => Uri(scheme: 'https', host: h, port: port);

  CompanionPairing preferring(String h) => CompanionPairing(
    host: h,
    hosts: [h, ...hosts.where((x) => x != h)],
    port: port,
    fingerprint: fingerprint,
    token: token,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'hosts': hosts,
    'port': port,
    'fingerprint': fingerprint,
    'token': token,
  };
  static CompanionPairing fromJson(Map<String, dynamic> j) => CompanionPairing(
    host: j['host'] as String,
    hosts: (j['hosts'] as List?)?.cast<String>(),
    port: j['port'] as int,
    fingerprint: j['fingerprint'] as String,
    token: j['token'] as String,
  );
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

/// Where the pairing (with this device's token) is kept: the Android Keystore /
/// iOS Keychain (this device only, never synced). A pairing saved by an older
/// version in plain SharedPreferences is moved there on first load.
class CompanionStore {
  static const _key = 'uata.companion.pairing';
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static Future<CompanionPairing?> load() async {
    var raw = await _secure.read(key: _key);
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_key);
    if (legacy != null) {
      raw ??= legacy;
      await _secure.write(key: _key, value: raw);
      await prefs.remove(_key); // never leave the token in plain storage
    }
    if (raw == null) return null;
    try {
      return CompanionPairing.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CompanionPairing p) => _secure.write(key: _key, value: jsonEncode(p.toJson()));

  static Future<void> clear() async {
    await _secure.delete(key: _key);
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}

/// Exchange the one-time code for this device's token (over the pinned TLS connection).
/// Each address in the link is tried until one answers; an answer that refuses the code ends it.
Future<CompanionPairing> pairWithComputer(PairingLink link, String deviceName, {http.Client? client}) async {
  final c = client ?? pinnedClient(link.fingerprint);
  EngineException? last;
  try {
    for (final h in link.hosts) {
      http.Response r;
      try {
        r = await c
            .post(
              Uri(scheme: 'https', host: h, port: link.port, path: '/companion/pair'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'code': link.code, 'name': deviceName}),
            )
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        last = EngineException(0, 'computer unreachable at $h: $e');
        continue; // try the next address
      }
      final body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200) {
        throw EngineException(r.statusCode, body is Map ? '${body['detail']}' : 'pairing failed');
      }
      return CompanionPairing(
        host: h,
        hosts: link.hosts,
        port: link.port,
        fingerprint: link.fingerprint,
        token: (body as Map)['token'] as String,
      ).preferring(h);
    }
    throw last ?? EngineException(0, 'computer unreachable');
  } finally {
    if (client == null) c.close();
  }
}

/// The first address of the computer that answers (pinned TLS), or null if none does.
Future<String?> reachableHost(CompanionPairing p, {http.Client? client}) async {
  final c = client ?? pinnedClient(p.fingerprint, connectTimeout: const Duration(seconds: 3));
  try {
    for (final h in p.hosts) {
      try {
        final r = await c.get(p.urlFor(h).replace(path: '/health')).timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) return h;
      } catch (_) {
        // next address
      }
    }
    return null;
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
  Future<EngineApi> connect() async {
    var p = pairing;
    if (p.hosts.length > 1) {
      final h = await reachableHost(p);
      if (h != null && h != p.host) {
        p = p.preferring(h);
        await CompanionStore.save(p); // remember the address that works
      }
    }
    return HttpEngineApi(
      baseUrl: p.baseUrl,
      tokenProvider: () async => pairing.token,
      authHeader: 'X-UATA-Device',
      client: pinnedClient(p.fingerprint),
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  void dispose() {}
}
