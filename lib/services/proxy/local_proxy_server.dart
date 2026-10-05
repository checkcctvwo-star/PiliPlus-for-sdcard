import 'dart:io';
import 'dart:async';
import 'package:mime/mime.dart';
import 'package:get/get.dart';

class LocalProxyServer extends GetxService {
  HttpServer? _server;
  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  @override
  void onInit() {
    super.onInit();
    start();
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }

  /// Start the local HTTP proxy server.
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest, onError: (e) => print("LocalProxyServer stream error: $e"));
  }

  /// Stop the server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Get the proxy URL for a given local file path.
  
  Future<void> ensureServerRunning() async {
    if (!isRunning) {
      await start();
    } else {
      try {
        final request = await HttpClient().get('127.0.0.1', port, '/ping').timeout(const Duration(milliseconds: 500));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) throw Exception('bad status');
      } catch (_) {
        await stop();
        await start();
      }
    }
  }

  Future<String> getProxyUrlAsync(String filePath) async {
    await ensureServerRunning();
    final encodedPath = Uri.encodeComponent(filePath);
    return 'http://127.0.0.1:$port/stream?path=$encodedPath';
  }

  String getProxyUrl(String filePath) {
    if (!isRunning) {
      throw StateError('Proxy server is not running');
    }
    final encodedPath = Uri.encodeComponent(filePath);
    return 'http://127.0.0.1:$port/stream?path=$encodedPath';
  }

  
  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path == '/ping') {
        response.statusCode = HttpStatus.ok;
        response.write('pong');
        return;
      }
      
      if (request.uri.path != '/stream') {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      final filePath = request.uri.queryParameters['path'];
      if (filePath == null || filePath.isEmpty) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      final fileStat = await file.stat();
      final fileSize = fileStat.size;

      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
      response.headers.contentType = ContentType.parse(mimeType);
      response.headers.set('Accept-Ranges', 'bytes');

      // Empty file: there is no valid [start, end] pair at all (end would be
      // -1 and contentLength would become 1). Answer 200 with an empty body
      // instead of handing negative offsets to File.openRead.
      if (fileSize == 0) {
        response.statusCode = HttpStatus.ok;
        response.headers.contentLength = 0;
        return;
      }

      int start = 0;
      int end = fileSize - 1;
      // Whether we settled on a valid byte range (206) or must fall back to
      // the full representation (200). Kept as an explicit flag so that there
      // is exactly ONE 206 output path below and suffix ranges — which are
      // normalised to a plain [start, end] pair above — can never be confused
      // with a 0-based full-file response.
      bool partial = false;

      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && rangeHeader.trim().startsWith('bytes=')) {
        // Multi-range ("bytes=0-100,200-300") is legal per RFC 7233 and the
        // server may answer 200 with the full body. libmpv only ever issues a
        // single range for seeking, so honour just the first spec instead of
        // building a multipart/byteranges response.
        final spec = rangeHeader.trim().substring(6).split(',').first.trim();
        final dash = spec.indexOf('-');
        if (dash != -1) {
          // `left` is everything before the first '-', so it can never itself
          // be negative; `right` may be empty ("bytes=N-") or, when `left` is
          // empty, a suffix length ("bytes=-N").
          final left = spec.substring(0, dash).trim();
          final right = spec.substring(dash + 1).trim();
          int? s;
          int? e;
          try {
            if (left.isEmpty && right.isNotEmpty) {
              // Suffix range "bytes=-N": the last N bytes. Normalise it to an
              // explicit [fileSize - N, fileSize - 1] pair here so the response
              // path below stays branch-free and can never confuse "start==0"
              // with a full-file 200.
              final n = int.parse(right);
              // "bytes=-0" asks for zero bytes, which RFC 7233 calls
              // unsatisfiable. Rather than answering 416 with no body we treat
              // it as a degenerate range and ignore the header, returning the
              // full 200 representation — players never send it and a 200 is
              // always a safe fallback.
              if (n > 0) {
                s = n >= fileSize ? 0 : fileSize - n;
                e = fileSize - 1;
              }
            } else if (left.isNotEmpty) {
              s = int.parse(left);
              // "bytes=N-" means "from N to the end of the file".
              e = right.isEmpty ? fileSize - 1 : int.parse(right);
            }
          } on FormatException {
            // Malformed spec ("bytes=abc-def", "bytes=-xyz"): RFC 7233 allows
            // ignoring the header. s stays null -> full 200 below. This
            // FormatException must never escape to the outer catch, otherwise
            // the client would see a 500 instead of a protocol response.
            s = null;
          }
          if (s != null && e != null) {
            if (s >= fileSize) {
              // Only an out-of-range START is unsatisfiable; an end past the
              // last byte is merely clamped (see the else branch). Tested
              // before the e < s case so that "bytes=<fileSize>-" is reported
              // as an out-of-range start rather than a reversed range.
              response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              response.headers.set('Content-Range', 'bytes */$fileSize');
              return;
            } else if (e < s) {
              // last-byte-pos < first-byte-pos: unsatisfiable per RFC 7233.
              response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              response.headers.set('Content-Range', 'bytes */$fileSize');
              return;
            } else {
              // Clamp an end past the last byte. The range is still
              // satisfiable, so this must stay a 206 and not degrade to 416.
              if (e >= fileSize) e = fileSize - 1;
              start = s;
              end = e;
              partial = true;
            }
          }
        }
      }

      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set('Content-Range', 'bytes $start-$end/$fileSize');
      } else {
        // No usable range: serve the whole file.
        start = 0;
        end = fileSize - 1;
        response.statusCode = HttpStatus.ok;
      }

      // Invariant guard: openRead throws RangeError (not ArgumentError) on a
      // bad offset, so never let a negative/out-of-file value reach it.
      if (start < 0 || end < start || start >= fileSize) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */$fileSize');
        return;
      }

      final contentLength = end - start + 1;
      response.headers.contentLength = contentLength;

      await response.addStream(file.openRead(start, end + 1));
    } on SocketException catch (_) {
      // Ignore broken pipe errors when the player closes the connection early
    } catch (e) {
      try {
        if (request.response.connectionInfo != null) {
          response.statusCode = HttpStatus.internalServerError;
        }
      } catch (_) {}
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

}
