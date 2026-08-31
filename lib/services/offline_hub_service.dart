// lib/services/offline_hub_service.dart
//
// OfflineHubService
// ----------------------------------------------------------------------------
// Connection manager for local inference servers (Ollama / LM Studio /
// LocalAI) and an offline-cached Dart/Flutter API doc lookup, for use when
// the device has no internet connectivity.
//
// LAN "auto-detect" here means: probe a short list of conventional
// hosts/ports (localhost, the Android-emulator host alias 10.0.2.2, and the
// device's own /24 subnet gateway guess) rather than a full network sweep,
// which would be slow and intrusive on a phone. Manual entry is always
// offered as the primary path.
// ----------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

enum LocalServerKind { ollama, lmStudio, localAI }

class LocalServerConfig {
  final String host; // e.g. http://192.168.1.15:11434
  final LocalServerKind kind;
  const LocalServerConfig({required this.host, required this.kind});
}

class LocalModelInfo {
  final String name;
  final String? sizeLabel;
  LocalModelInfo({required this.name, this.sizeLabel});
}

class ServerProbeResult {
  final String host;
  final bool reachable;
  final Duration? latency;
  final List<LocalModelInfo> models;
  final String? error;

  ServerProbeResult({
    required this.host,
    required this.reachable,
    this.latency,
    this.models = const [],
    this.error,
  });
}

class OfflineHubService {
  OfflineHubService._internal();
  static final OfflineHubService instance = OfflineHubService._internal();

  static const _kSavedHostPref = 'offline_hub_host';
  static const _kSavedKindPref = 'offline_hub_kind';

  /// Common hosts to try during "Auto-Detect". Order matters: emulator
  /// alias first, then localhost, then a couple of common home-LAN guesses.
  static const List<String> commonCandidateHosts = [
    'http://10.0.2.2:11434', // Android emulator -> host loopback (Ollama)
    'http://127.0.0.1:11434',
    'http://localhost:11434',
    'http://10.0.2.2:1234', // LM Studio default port via emulator alias
    'http://127.0.0.1:1234',
  ];

  Database? _db;

  Future<void> saveActiveServer(LocalServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSavedHostPref, config.host);
    await prefs.setString(_kSavedKindPref, config.kind.name);
  }

  Future<LocalServerConfig?> loadActiveServer() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_kSavedHostPref);
    final kindName = prefs.getString(_kSavedKindPref);
    if (host == null || kindName == null) return null;
    final kind = LocalServerKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => LocalServerKind.ollama,
    );
    return LocalServerConfig(host: host, kind: kind);
  }

  /// Probes a single host for reachability, latency, and available models.
  /// Tries the Ollama `/api/tags` endpoint first, then falls back to the
  /// OpenAI-compatible `/v1/models` endpoint used by LM Studio/LocalAI.
  Future<ServerProbeResult> probeServer(String host) async {
    final sw = Stopwatch()..start();
    try {
      // Try Ollama-native endpoint.
      final ollamaResp = await http
          .get(Uri.parse('$host/api/tags'))
          .timeout(const Duration(seconds: 3));
      if (ollamaResp.statusCode == 200) {
        sw.stop();
        final data = jsonDecode(ollamaResp.body) as Map<String, dynamic>;
        final models = (data['models'] as List<dynamic>? ?? [])
            .map((m) => LocalModelInfo(
                  name: (m['name'] ?? 'unknown') as String,
                  sizeLabel: _formatBytes(m['size']),
                ))
            .toList();
        return ServerProbeResult(
          host: host,
          reachable: true,
          latency: sw.elapsed,
          models: models,
        );
      }
    } catch (_) {
      // Fall through to OpenAI-compatible probe.
    }

    try {
      final openAiResp = await http
          .get(Uri.parse('$host/v1/models'))
          .timeout(const Duration(seconds: 3));
      sw.stop();
      if (openAiResp.statusCode == 200) {
        final data = jsonDecode(openAiResp.body) as Map<String, dynamic>;
        final models = (data['data'] as List<dynamic>? ?? [])
            .map((m) => LocalModelInfo(name: (m['id'] ?? 'unknown') as String))
            .toList();
        return ServerProbeResult(
          host: host,
          reachable: true,
          latency: sw.elapsed,
          models: models,
        );
      }
      return ServerProbeResult(
        host: host,
        reachable: false,
        error: 'HTTP ${openAiResp.statusCode}',
      );
    } catch (e) {
      sw.stop();
      return ServerProbeResult(host: host, reachable: false, error: e.toString());
    }
  }

  /// Probes every candidate host concurrently and returns only the
  /// reachable ones, sorted by latency (fastest first).
  Future<List<ServerProbeResult>> autoDetect({List<String>? extraHosts}) async {
    final hosts = [...commonCandidateHosts, ...?extraHosts];
    final results = await Future.wait(hosts.map(probeServer));
    final reachable = results.where((r) => r.reachable).toList()
      ..sort((a, b) => (a.latency ?? Duration.zero).compareTo(b.latency ?? Duration.zero));
    return reachable;
  }

  String? _formatBytes(dynamic bytes) {
    if (bytes == null) return null;
    final n = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (n <= 0) return null;
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = n.toDouble();
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  // --------------------------------------------------------------------
  // Offline cached documentation lookup (sqflite)
  // --------------------------------------------------------------------

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'cortex_offline_docs.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE docs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol TEXT NOT NULL,
            package TEXT NOT NULL,
            summary TEXT NOT NULL,
            signature TEXT,
            UNIQUE(symbol, package)
          )
        ''');
        await db.execute('CREATE INDEX idx_docs_symbol ON docs(symbol)');
      },
    );
    return _db!;
  }

  /// Seeds (or upserts) the offline doc cache. Call this once, e.g. from a
  /// bundled JSON asset, whenever the app has connectivity, so lookups work
  /// later while offline.
  Future<void> cacheDocEntry({
    required String symbol,
    required String package,
    required String summary,
    String? signature,
  }) async {
    final db = await _database();
    await db.insert(
      'docs',
      {
        'symbol': symbol,
        'package': package,
        'summary': summary,
        'signature': signature,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> lookupDoc(String symbol) async {
    final db = await _database();
    return db.query(
      'docs',
      where: 'symbol LIKE ?',
      whereArgs: ['%$symbol%'],
      limit: 20,
    );
  }
}
