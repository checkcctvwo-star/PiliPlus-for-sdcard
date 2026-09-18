import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/proxy/local_proxy_server.dart';
import 'package:dio/dio.dart';

void main() {
  group('LocalProxyServer', () {
    late LocalProxyServer proxyServer;
    late File testVideoFile;
    final dio = Dio();

    setUpAll(() async {
      proxyServer = LocalProxyServer();
      await proxyServer.start();

      testVideoFile = File('test_video.mp4');
      // Create a dummy file of 1MB
      final bytes = List<int>.generate(1024 * 1024, (i) => i % 256);
      await testVideoFile.writeAsBytes(bytes);
    });

    tearDownAll(() async {
      await proxyServer.stop();
      if (await testVideoFile.exists()) {
        await testVideoFile.delete();
      }
    });

    test('should start and stop successfully', () async {
      final server = LocalProxyServer();
      expect(server.isRunning, isFalse);
      
      await server.start();
      expect(server.isRunning, isTrue);
      expect(server.port, greaterThan(0));
      
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('should serve full file without Range header', () async {
      final url = proxyServer.getProxyUrl(testVideoFile.path);
      final response = await dio.get(url, options: Options(responseType: ResponseType.bytes));
      
      expect(response.statusCode, 200);
      expect(response.headers.value('content-type'), 'video/mp4');
      expect(response.headers.value('accept-ranges'), 'bytes');
      
      final data = response.data as List<int>;
      expect(data.length, 1024 * 1024);
      expect(data[0], 0);
      expect(data[1024 * 1024 - 1], (1024 * 1024 - 1) % 256);
    });

    test('should serve partial file with Range header (start-end)', () async {
      final url = proxyServer.getProxyUrl(testVideoFile.path);
      final response = await dio.get(
        url,
        options: Options(
          headers: {'Range': 'bytes=100-199'},
          responseType: ResponseType.bytes,
        ),
      );
      
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 100-199/1048576');
      
      final data = response.data as List<int>;
      expect(data.length, 100);
      expect(data[0], 100 % 256);
      expect(data[99], 199 % 256);
    });

    test('should serve partial file with Range header (start only)', () async {
      final url = proxyServer.getProxyUrl(testVideoFile.path);
      final response = await dio.get(
        url,
        options: Options(
          headers: {'Range': 'bytes=1000000-'},
          responseType: ResponseType.bytes,
        ),
      );
      
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 1000000-1048575/1048576');
      
      final data = response.data as List<int>;
      expect(data.length, 48576);
      expect(data[0], 1000000 % 256);
    });

    test('should return 416 for invalid range', () async {
      final url = proxyServer.getProxyUrl(testVideoFile.path);
      try {
        await dio.get(
          url,
          options: Options(
            headers: {'Range': 'bytes=2000000-3000000'},
            responseType: ResponseType.bytes,
          ),
        );
        fail('Should throw DioException');
      } on DioException catch (e) {
        expect(e.response?.statusCode, 416);
        expect(e.response?.headers.value('content-range'), 'bytes */1048576');
      }
    });

    test('should return 404 for non-existent file', () async {
      final url = proxyServer.getProxyUrl('non_existent.mp4');
      try {
        await dio.get(url);
        fail('Should throw DioException');
      } on DioException catch (e) {
        expect(e.response?.statusCode, 404);
      }
    });
  });
}
