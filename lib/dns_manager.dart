import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Local DNS inventory backed by SQLite.
///
/// The database is intentionally queried in pages: large imports should not
/// require loading the complete DNS inventory into RAM.
class DnsManager {
  static const _sourcesKey = 'dns_sources';
  static const _masterPoolKey = 'master_dns_pool';
  static const _displayListKey = 'display_dns_list';
  static const _legacyMigrationKey = 'dns_sqlite_legacy_migrated_v1';
  static const _table = 'dns_servers';
  static const _pageSize = 1000;

  Future<Database>? _databaseFuture;

  final List<String> premiumGamingDns = const [
    '78.157.42.100',
    '176.119.1.1',
    '10.202.10.10',
    '119.29.29.29',
    '223.5.5.5',
    '8.26.56.26',
    '209.244.0.3',
    '1.1.1.1',
    '8.8.8.8',
  ];

  /// Reliable public sources. The app reports source failures instead of
  /// inventing or silently injecting fake/offline DNS entries.
  final List<String> _networkSources = const [
    'https://public-dns.info/nameservers.txt',
    'https://raw.githubusercontent.com/blacklanternsecurity/public-dns-servers/main/nameservers.txt',
    'https://raw.githubusercontent.com/pingproxies/public-dns-directory/main/resolvers/global/all.txt',
    'https://raw.githubusercontent.com/takuya/public_dns_list/master/dns-list-ipv4.txt',
  ];

  Future<Database> get _database => _databaseFuture ??= _openDatabase();

  Future<Database> _openDatabase() async {
    final databaseDirectory = await getDatabasesPath();
    final databasePath = path.join(databaseDirectory, 'gaming_dns.sqlite');

    final db = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE $_table (
            ip TEXT PRIMARY KEY,
            ping_ms INTEGER,
            tested_at INTEGER,
            source TEXT NOT NULL DEFAULT 'manual',
            is_premium INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await database.execute(
          'CREATE INDEX idx_dns_ping ON $_table(ping_ms)',
        );
        await database.execute(
          'CREATE INDEX idx_dns_premium ON $_table(is_premium)',
        );

        final now = DateTime.now().millisecondsSinceEpoch;
        final batch = database.batch();
        for (final ip in premiumGamingDns) {
          batch.insert(
            _table,
            {
              'ip': ip,
              'source': 'built-in',
              'is_premium': 1,
              'created_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      },
    );

    // One-time import of data stored by older releases in SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_legacyMigrationKey) ?? false)) {
      final legacyIps = <String>{
        ...?prefs.getStringList(_masterPoolKey),
        ...?prefs.getStringList(_displayListKey),
      };
      if (legacyIps.isNotEmpty) {
        await _insertIps(
          db,
          legacyIps,
          source: 'legacy-migration',
        );
      }
      await prefs.setBool(_legacyMigrationKey, true);
    }

    return db;
  }

  /// Validates the syntax of an IPv4 or IPv6 address. Private/local addresses
  /// are allowed for manually entered DNS servers.
  bool isValidIp(String ip) {
    final value = ip.trim();
    if (value.isEmpty || value.contains('%')) return false;
    final address = InternetAddress.tryParse(value);
    return address != null &&
        (address.type == InternetAddressType.IPv4 ||
            address.type == InternetAddressType.IPv6);
  }

  bool _isPubliclyRoutable(String ip) {
    final address = InternetAddress.tryParse(ip);
    if (address == null) return false;

    if (address.type == InternetAddressType.IPv6) {
      final normalized = ip.toLowerCase();
      // Public global-unicast IPv6 addresses are in 2000::/3. This excludes
      // loopback, link-local, unique-local, multicast and unspecified values.
      return normalized.startsWith('2') || normalized.startsWith('3');
    }

    final octets = ip.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((part) => part == null)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;
    final c = octets[2]!;
    final d = octets[3]!;

    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 192 && b == 0 && c == 0) return false;
    if (a == 192 && b == 0 && c == 2) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a == 198 && b == 51 && c == 100) return false;
    if (a == 203 && b == 0 && c == 113) return false;
    if (a == 255 && b == 255 && c == 255 && d == 255) return false;
    return true;
  }

  List<String> extractIpsFromText(String text, {bool publicOnly = false}) {
    final found = <String>{};
    final ipv4Pattern = RegExp(
      r'(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)',
    );
    // A deliberately broad candidate matcher is followed by InternetAddress
    // validation, which removes non-IP strings from mixed TXT/JSON/CSV files.
    final ipv6Pattern = RegExp(r'[0-9A-Fa-f:]{2,}');

    for (final match in ipv4Pattern.allMatches(text)) {
      final ip = match.group(0)!.trim();
      if (isValidIp(ip) && (!publicOnly || _isPubliclyRoutable(ip))) {
        found.add(ip);
      }
    }
    for (final match in ipv6Pattern.allMatches(text)) {
      final ip = match.group(0)!.trim();
      if (ip.contains(':') &&
          isValidIp(ip) &&
          (!publicOnly || _isPubliclyRoutable(ip))) {
        found.add(ip);
      }
    }
    return found.toList(growable: false);
  }

  Future<int> _insertIps(
    DatabaseExecutor executor,
    Iterable<String> ips, {
    required String source,
    int? limit,
  }) async {
    if (limit != null && limit <= 0) return 0;

    final unique = <String>{};
    for (final rawIp in ips) {
      final address = InternetAddress.tryParse(rawIp.trim());
      if (address != null && isValidIp(address.address)) {
        unique.add(address.address);
      }
    }

    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final ip in unique) {
      if (limit != null && inserted >= limit) break;
      final rowId = await executor.insert(
        _table,
        {
          'ip': ip,
          'source': source,
          'is_premium': 0,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (rowId != 0) inserted++;
    }
    return inserted;
  }

  /// Inserts valid IPs without duplicates. If [limit] is provided, it limits
  /// newly inserted records, not merely the number of input lines.
  Future<int> addIps(
    Iterable<String> ips, {
    required String source,
    int? limit,
  }) async {
    if (limit != null && limit <= 0) return 0;
    final db = await _database;
    var inserted = 0;
    await db.transaction((txn) async {
      inserted = await _insertIps(
        txn,
        ips,
        source: source,
        limit: limit,
      );
    });
    return inserted;
  }

  Future<int> getDnsCount() async {
    final db = await _database;
    final result = await db.rawQuery('SELECT COUNT(*) AS count FROM $_table');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<Map<String, Object?>>> getDnsPage({
    int offset = 0,
    int limit = 100,
    bool sortByPing = false,
  }) async {
    final db = await _database;
    return db.query(
      _table,
      columns: ['ip', 'ping_ms', 'is_premium', 'source', 'tested_at'],
      orderBy: sortByPing
          ? 'is_premium DESC, CASE WHEN ping_ms IS NULL THEN 1 ELSE 0 END, ping_ms ASC, created_at DESC, ip ASC'
          : 'is_premium DESC, created_at DESC, ip ASC',
      limit: limit,
      offset: offset,
    );
  }

  Future<void> updatePingResult(String ip, int pingMs) async {
    final db = await _database;
    await db.update(
      _table,
      {
        'ping_ms': pingMs,
        'tested_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'ip = ?',
      whereArgs: [ip],
    );
  }

  Future<int> deleteIps(Iterable<String> ips) async {
    final values = ips.toSet().toList(growable: false);
    if (values.isEmpty) return 0;
    final db = await _database;
    var deleted = 0;
    for (var i = 0; i < values.length; i += 400) {
      final end = (i + 400 < values.length) ? i + 400 : values.length;
      final chunk = values.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      deleted += await db.delete(
        _table,
        where: 'ip IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    return deleted;
  }

  Future<int> deleteInvalidDns() async {
    final db = await _database;
    var deleted = 0;
    String lastIp = '';

    while (true) {
      final rows = await db.query(
        _table,
        columns: ['ip'],
        where: 'ip > ?',
        whereArgs: [lastIp],
        orderBy: 'ip ASC',
        limit: _pageSize,
      );
      if (rows.isEmpty) break;

      final ips = rows.map((row) => row['ip']! as String).toList();
      lastIp = ips.last;
      final invalid = ips.where((ip) => !isValidIp(ip)).toList();
      deleted += await deleteIps(invalid);
    }
    return deleted;
  }

  Future<int> deleteUnresponsiveDns() async {
    final db = await _database;
    return db.delete(_table, where: 'ping_ms >= ?', whereArgs: [9999]);
  }

  Future<int> deleteDnsAboveLatency(int maxMs) async {
    final db = await _database;
    return db.delete(
      _table,
      where: 'ping_ms IS NOT NULL AND ping_ms > ?',
      whereArgs: [maxMs],
    );
  }

  Future<void> deleteAllDns() async {
    final db = await _database;
    await db.delete(_table);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_masterPoolKey);
    await prefs.remove(_displayListKey);
  }

  Future<void> saveSources(List<String> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_sourcesKey, sources.toSet().toList());
  }

  Future<List<String>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_sourcesKey) ?? <String>[];
  }

  /// Imports at most [limit] newly added records from public DNS sources and
  /// custom HTTPS sources. The source's actual size may be lower than the
  /// requested amount; the result reports what was really inserted.
  Future<Map<String, dynamic>> fetchFromNetwork({required int limit}) async {
    if (limit <= 0) {
      return {
        'status': 'error',
        'count': 0,
        'sources_succeeded': 0,
        'sources_failed': 0,
      };
    }

    final customSources = await loadSources();
    final sources = <String>{..._networkSources, ...customSources}.toList();
    final client = http.Client();
    var insertedTotal = 0;
    var succeeded = 0;
    var failed = 0;

    try {
      for (final sourceUrl in sources) {
        if (insertedTotal >= limit) break;
        final uri = Uri.tryParse(sourceUrl);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
          failed++;
          continue;
        }

        try {
          final request = http.Request('GET', uri)
            ..headers['User-Agent'] = 'GamingDNS/2.0';
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 20));

          if (response.statusCode != 200) {
            failed++;
            await response.stream.drain<void>();
            continue;
          }
          succeeded++;

          final candidates = <String>{};
          await for (final line in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            candidates.addAll(extractIpsFromText(line, publicOnly: true));
            if (candidates.length >= 500) {
              final remaining = limit - insertedTotal;
              insertedTotal += await addIps(
                candidates,
                source: sourceUrl,
                limit: remaining,
              );
              candidates.clear();
              if (insertedTotal >= limit) break;
            }
          }

          if (candidates.isNotEmpty && insertedTotal < limit) {
            insertedTotal += await addIps(
              candidates,
              source: sourceUrl,
              limit: limit - insertedTotal,
            );
          }
        } catch (_) {
          failed++;
        }
      }
    } finally {
      client.close();
    }

    return {
      'status': succeeded > 0 ? 'success' : 'error',
      'count': insertedTotal,
      'sources_succeeded': succeeded,
      'sources_failed': failed,
    };
  }

  /// Imports a large text file incrementally so it does not need to be loaded
  /// entirely into memory. [limit] applies to new database records.
  Future<int> importFile(File file, {required int limit}) async {
    if (limit <= 0) return 0;

    var inserted = 0;
    final candidates = <String>{};
    await for (final line in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      candidates.addAll(extractIpsFromText(line));
      if (candidates.length >= 500) {
        inserted += await addIps(
          candidates,
          source: 'file-import',
          limit: limit - inserted,
        );
        candidates.clear();
        if (inserted >= limit) break;
      }
    }

    if (candidates.isNotEmpty && inserted < limit) {
      inserted += await addIps(
        candidates,
        source: 'file-import',
        limit: limit - inserted,
      );
    }
    return inserted;
  }

  /// Sends a real DNS-over-UDP A query and measures the response time. A TCP
  /// connection to port 53 alone is not a reliable DNS health check.
  Future<int?> testDns(
    String ip, {
    Duration timeout = const Duration(milliseconds: 1800),
  }) async {
    final address = InternetAddress.tryParse(ip.trim());
    if (address == null) return null;

    final random = Random.secure();
    final transactionId = random.nextInt(65536);
    final query = <int>[
      (transactionId >> 8) & 0xff,
      transactionId & 0xff,
      0x01,
      0x00, // recursion desired
      0x00,
      0x01, // one question
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      7,
      ...ascii.encode('example'),
      3,
      ...ascii.encode('com'),
      0,
      0,
      1, // QTYPE A
      0,
      1, // QCLASS IN
    ];

    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    final completer = Completer<int?>();
    final stopwatch = Stopwatch()..start();

    try {
      final bindAddress = address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4;
      final datagramSocket = await RawDatagramSocket.bind(bindAddress, 0);
      socket = datagramSocket;
      subscription = datagramSocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = datagramSocket.receive();
        if (datagram == null || datagram.data.length < 12) return;
        final data = datagram.data;
        final responseId = (data[0] << 8) | data[1];
        if (responseId != transactionId) return;
        final flags = (data[2] << 8) | data[3];
        final isResponse = (flags & 0x8000) != 0;
        final responseCode = flags & 0x000f;
        if (!completer.isCompleted) {
          if (isResponse && responseCode == 0) {
            stopwatch.stop();
            final elapsed = stopwatch.elapsedMilliseconds;
            completer.complete(elapsed < 1 ? 1 : elapsed);
          } else {
            completer.complete(null);
          }
        }
      });

      datagramSocket.send(query, address, 53);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
  }

  Future<File?> generateExportFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/Gaming_DNS_Backup.txt');
      final sink = file.openWrite();
      var offset = 0;

      while (true) {
        final rows = await getDnsPage(offset: offset, limit: _pageSize);
        if (rows.isEmpty) break;
        for (final row in rows) {
          sink.writeln(row['ip'] as String);
        }
        offset += rows.length;
        if (rows.length < _pageSize) break;
      }

      await sink.flush();
      await sink.close();
      return file;
    } catch (_) {
      return null;
    }
  }
}
