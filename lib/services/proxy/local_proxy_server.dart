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
    _server!.listen(_handleRequest);
  }

  /// Stop the server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Get the proxy URL for a given local file path.
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
      if (request.uri.path != '/stream') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final filePath = request.uri.queryParameters['path'];
      if (filePath == null || filePath.isEmpty) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final fileStat = await file.stat();
      final fileSize = fileStat.size;

      // Determine MIME type
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
      response.headers.contentType = ContentType.parse(mimeType);
      response.headers.set('Accept-Ranges', 'bytes');

      int start = 0;
      int end = fileSize - 1;

      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        if (parts.isNotEmpty) {
          if (parts[0].isNotEmpty) {
            start = int.parse(parts[0]);
          }
          if (parts.length > 1 && parts[1].isNotEmpty) {
            end = int.parse(parts[1]);
          }
        }
        
        if (start >= fileSize || end >= fileSize || start > end) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range', 'bytes */$fileSize');
          await response.close();
          return;
        }

        response.statusCode = HttpStatus.partialContent;
        response.headers.set('Content-Range', 'bytes $start-$end/$fileSize');
      } else {
        response.statusCode = HttpStatus.ok;
      }

      final contentLength = end - start + 1;
      response.headers.contentLength = contentLength;

      await response.addStream(file.openRead(start, end + 1));
    } catch (e) {
      if (request.response.connectionInfo != null) {
        response.statusCode = HttpStatus.internalServerError;
      }
    } finally {
      await response.close();
    }
  }
}
