import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'network_utils.dart';
import 'handlers/accounts_handler.dart';
import 'handlers/budgets_handler.dart';
import 'handlers/transactions_handler.dart';
import 'handlers/summary_handler.dart';
import 'handlers/banks_handler.dart';
import 'handlers/categories_handler.dart';
import 'handlers/shared_accounts_handler.dart';

/// Log entry for request logging
class ServerLogEntry {
  final DateTime timestamp;
  final String method;
  final String path;
  final int statusCode;
  final String? message;
  final Duration? duration;

  ServerLogEntry({
    required this.timestamp,
    required this.method,
    required this.path,
    required this.statusCode,
    this.message,
    this.duration,
  });

  @override
  String toString() {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
    final durationStr =
        duration != null ? ' (${duration!.inMilliseconds}ms)' : '';
    return '[$time] $method $path → $statusCode$durationStr';
  }
}

class ServerService {
  HttpServer? _server;
  String? _localIp;
  Directory? _webappDir;
  String? _accessKey;
  Timer? _idleTimer;

  static const String _accessKeyParam = 'key';
  static const String _accessCookie = 'totals_dashboard_key';

  /// The server stops itself after this long without an authorized request,
  /// so a forgotten dashboard doesn't keep financial data on the network.
  static const Duration idleTimeout = Duration(minutes: 15);

  final StreamController<void> _idleStopController =
      StreamController<void>.broadcast();

  /// Fires when the server stops itself after [idleTimeout].
  Stream<void> get idleStopStream => _idleStopController.stream;

  // Request logging
  final StreamController<ServerLogEntry> _logController =
      StreamController<ServerLogEntry>.broadcast();
  final List<ServerLogEntry> _logs = [];
  static const int _maxLogs = 100;

  /// Stream of log entries
  Stream<ServerLogEntry> get logStream => _logController.stream;

  /// Get all logs
  List<ServerLogEntry> get logs => List.unmodifiable(_logs);

  /// Add a log entry
  void _addLog(ServerLogEntry entry) {
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    _logController.add(entry);
  }

  /// Clear all logs
  void clearLogs() {
    _logs.clear();
  }

  // Shared random number state
  int _currentRandomNumber = 0;
  final Random _random = Random();
  final StreamController<int> _randomNumberController =
      StreamController<int>.broadcast();

  /// Stream of random number updates
  Stream<int> get randomNumberStream => _randomNumberController.stream;

  /// Current random number
  int get currentRandomNumber => _currentRandomNumber;

  /// Generate a new random number and notify listeners
  void generateRandomNumber() {
    _currentRandomNumber = _random.nextInt(10000);
    _randomNumberController.add(_currentRandomNumber);
  }

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  String? get serverUrl {
    if (_server == null || _localIp == null) return null;
    return 'http://$_localIp:${_server!.port}';
  }

  String? get localUrl {
    if (_server == null) return null;
    return 'http://localhost:${_server!.port}';
  }

  /// Dashboard link including the access key. Share this, not [serverUrl].
  String? get accessUrl {
    final base = serverUrl;
    if (base == null || _accessKey == null) return null;
    return '$base/?$_accessKeyParam=$_accessKey';
  }

  /// API docs link including the access key.
  String? get docsUrl {
    final base = serverUrl;
    if (base == null || _accessKey == null) return null;
    return '$base/docs?$_accessKeyParam=$_accessKey';
  }

  /// Key for `Authorization: Bearer` when calling the API from scripts.
  String? get accessKey => _accessKey;

  Future<void> startServer({int port = 8080}) async {
    if (_server != null) {
      print('Server already running');
      return;
    }

    _localIp = await NetworkUtils.getLocalIpAddress();
    if (_localIp == null) {
      throw Exception('Could not determine local IP address');
    }

    // Extract assets to a temporary directory
    await _extractAssetsToTemp();

    if (_webappDir == null) {
      throw Exception('Failed to extract webapp assets');
    }

    final router = Router();

    // Mount API handlers
    final accountsHandler = AccountsHandler();
    final sharedAccountsHandler = SharedAccountsHandler();
    final budgetsHandler = BudgetsHandler();
    final transactionsHandler = TransactionsHandler();
    final summaryHandler = SummaryHandler();
    final banksHandler = BanksHandler();
    final categoriesHandler = CategoriesHandler();

    router.mount('/api/accounts', accountsHandler.router.call);
    router.mount('/api/shared-accounts', sharedAccountsHandler.router.call);
    router.mount('/api/budgets', budgetsHandler.router.call);
    router.mount('/api/transactions', transactionsHandler.router.call);
    router.mount('/api/summary', summaryHandler.router.call);
    router.mount('/api/banks', banksHandler.router.call);
    router.mount('/api/categories', categoriesHandler.router.call);

    // Health check endpoint
    router.get('/health', (Request request) {
      return Response.ok('OK');
    });

    // API endpoint example
    router.get('/api/info', (Request request) {
      return Response.ok(
        '{"status": "running", "version": "1.0.0"}',
        headers: {'Content-Type': 'application/json'},
      );
    });

    // Get current random number endpoint
    router.get('/api/random', (Request request) {
      return Response.ok(
        jsonEncode({
          'number': _currentRandomNumber,
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // Generate new random number endpoint
    router.post('/api/random/generate', (Request request) {
      generateRandomNumber();
      return Response.ok(
        jsonEncode({
          'number': _currentRandomNumber,
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // Create static file handler using shelf_static
    final staticHandler = createStaticHandler(
      _webappDir!.path,
      defaultDocument: 'index.html',
      listDirectories: false,
    );

    // Cascade: try API routes first, then static files
    final cascade = Cascade()
        .add(router.call)
        .add(staticHandler)
        .add(_spaFallbackHandler); // SPA fallback for client-side routing

    final handler = const Pipeline()
        .addMiddleware(_loggingMiddleware())
        .addMiddleware(_privateNetworkMiddleware())
        .addMiddleware(_accessKeyMiddleware())
        .addHandler(cascade.handler);

    _accessKey = _generateAccessKey();
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    _resetIdleTimer();
    print('Server running at $serverUrl');
    print('Serving files from: ${_webappDir!.path}');
  }

  /// SPA fallback handler - serves index.html for unmatched routes
  Future<Response> _spaFallbackHandler(Request request) async {
    final indexFile = File('${_webappDir!.path}/index.html');
    if (await indexFile.exists()) {
      final content = await indexFile.readAsBytes();
      return Response.ok(
        content,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );
    }
    return Response.notFound('Not Found');
  }

  /// Extract Flutter assets to a temporary directory for shelf_static to serve
  Future<void> _extractAssetsToTemp() async {
    final tempDir = await getTemporaryDirectory();
    _webappDir = Directory('${tempDir.path}/flutter_server_webapp');

    // Clean up existing directory if it exists
    if (await _webappDir!.exists()) {
      await _webappDir!.delete(recursive: true);
    }
    await _webappDir!.create(recursive: true);

    // List of known asset files to extract
    // You may need to update this list based on your webapp structure
    final assetFiles = await _getAssetManifest();

    for (final assetPath in assetFiles) {
      if (assetPath.startsWith('assets/webapp/')) {
        await _extractAsset(assetPath);
      }
    }
  }

  /// Get list of assets from the asset manifest
  Future<List<String>> _getAssetManifest() async {
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = jsonDecode(manifestContent);
      return manifest.keys.toList();
    } catch (e) {
      print('Failed to load asset manifest: $e');
      // Fallback: try common files
      return ['assets/webapp/index.html', 'assets/webapp/vite.svg'];
    }
  }

  /// Extract a single asset to the temp directory
  Future<void> _extractAsset(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      // Remove 'assets/webapp/' prefix for the destination path
      final relativePath = assetPath.replaceFirst('assets/webapp/', '');
      final destFile = File('${_webappDir!.path}/$relativePath');

      // Create parent directories if needed
      await destFile.parent.create(recursive: true);

      // Write the file
      await destFile.writeAsBytes(bytes);
      print('Extracted: $assetPath -> ${destFile.path}');
    } catch (e) {
      print('Failed to extract asset $assetPath: $e');
    }
  }

  /// Logging middleware that emits to the log stream
  Middleware _loggingMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        final stopwatch = Stopwatch()..start();

        try {
          final response = await handler(request);
          stopwatch.stop();

          // Log the request
          _addLog(ServerLogEntry(
            timestamp: DateTime.now(),
            method: request.method,
            path: '/${request.url.path}',
            statusCode: response.statusCode,
            duration: stopwatch.elapsed,
          ));

          return response;
        } catch (e) {
          stopwatch.stop();

          _addLog(ServerLogEntry(
            timestamp: DateTime.now(),
            method: request.method,
            path: '/${request.url.path}',
            statusCode: 500,
            message: e.toString(),
            duration: stopwatch.elapsed,
          ));

          rethrow;
        }
      };
    };
  }

  /// Requires the per-session access key on every request, so other devices
  /// on the network and websites open in a browser cannot read or change
  /// financial data. Opening [accessUrl] trades the key in the link for an
  /// HttpOnly, SameSite=Lax cookie that the dashboard's same-origin
  /// requests then carry. Scripts can send `Authorization: Bearer <key>`.
  Middleware _accessKeyMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        final key = _accessKey;
        if (key == null) {
          return Response.forbidden('Server is not running.');
        }

        final queryKey = request.url.queryParameters[_accessKeyParam];
        if (queryKey != null && _constantTimeEquals(queryKey, key)) {
          final isApi = request.url.path.startsWith('api/');
          if (request.method == 'GET' && !isApi) {
            // Drop the key from the address bar so it doesn't linger in
            // browser history.
            final params = Map<String, String>.of(request.url.queryParameters)
              ..remove(_accessKeyParam);
            final query =
                params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
            return Response.found(
              '/${request.url.path}$query',
              headers: {
                'Set-Cookie':
                    '$_accessCookie=$key; Path=/; HttpOnly; SameSite=Lax',
                'Cache-Control': 'no-store',
              },
            );
          }
          _resetIdleTimer();
          return handler(request);
        }

        if (_hasValidCookie(request, key) || _hasValidBearer(request, key)) {
          _resetIdleTimer();
          return handler(request);
        }

        return Response(
          401,
          body: 'Open the private link shown in the Totals app.',
          headers: {'Content-Type': 'text/plain; charset=utf-8'},
        );
      };
    };
  }

  /// Refuses clients outside the local network, e.g. someone reaching the
  /// phone's public mobile-data address.
  Middleware _privateNetworkMiddleware() {
    return (Handler handler) {
      return (Request request) {
        final info = request.context['shelf.io.connection_info'];
        final address = info is HttpConnectionInfo ? info.remoteAddress : null;
        if (address == null || !NetworkUtils.isPrivateOrLoopback(address)) {
          return Response.forbidden(
            'The Totals dashboard is only available on your local network.',
          );
        }
        return handler(request);
      };
    };
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () async {
      if (_server == null) return;
      await stopServer();
      if (!_idleStopController.isClosed) _idleStopController.add(null);
    });
  }

  bool _hasValidCookie(Request request, String key) {
    final header = request.headers['cookie'];
    if (header == null) return false;
    for (final part in header.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      if (part.substring(0, separator).trim() != _accessCookie) continue;
      if (_constantTimeEquals(part.substring(separator + 1).trim(), key)) {
        return true;
      }
    }
    return false;
  }

  bool _hasValidBearer(Request request, String key) {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return false;
    return _constantTimeEquals(header.substring(7).trim(), key);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _generateAccessKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> stopServer() async {
    if (_server == null) {
      print('Server not running');
      return;
    }

    _idleTimer?.cancel();
    _idleTimer = null;
    await _server!.close(force: true);
    _server = null;
    _localIp = null;
    _accessKey = null;

    // Clean up temp directory
    if (_webappDir != null && await _webappDir!.exists()) {
      try {
        await _webappDir!.delete(recursive: true);
        print('Cleaned up temp webapp directory');
      } catch (e) {
        print('Failed to clean up temp directory: $e');
      }
    }
    _webappDir = null;

    print('Server stopped');
  }

  void dispose() {
    _idleTimer?.cancel();
    _idleStopController.close();
    _randomNumberController.close();
    _logController.close();
  }
}
