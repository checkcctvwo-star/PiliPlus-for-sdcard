import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/proxy/local_proxy_server.dart';
import 'package:dio/dio.dart';

/// Tests for RFC 7233 Range request handling in [LocalProxyServer].
///
/// These tests observe the server purely over HTTP (via dio) and never touch
/// private members, so they stay valid regardless of how the parsing is
/// implemented internally.
///
/// Reference file layout: 1 MiB file where the byte at offset `i` is `i % 256`.
///   fileSize = 1048576
///   last byte offset = 1048575
void main() {
  group('LocalProxyServer Range handling', () {
    late LocalProxyServer proxyServer;
    late File testVideoFile;
    final dio = Dio();

    const int fileSize = 1024 * 1024; // 1048576

    setUpAll(() async {
      proxyServer = LocalProxyServer();
      await proxyServer.start();

      testVideoFile = File('test_video_range.mp4');
      // Create a dummy file of 1MB, byte i == i % 256
      final bytes = List<int>.generate(fileSize, (i) => i % 256);
      await testVideoFile.writeAsBytes(bytes);
    });

    tearDownAll(() async {
      await proxyServer.stop();
      if (await testVideoFile.exists()) {
        await testVideoFile.delete();
      }
    });

    String url() => proxyServer.getProxyUrl(testVideoFile.path);

    Future<Response<dynamic>> get(String range) => dio.get(
          url(),
          options: Options(
            headers: {'Range': range},
            responseType: ResponseType.bytes,
          ),
        );

    group('suffix Range (Bug 1)', () {
      // RFC 7233 section 2.1: "bytes=-500" means "the last 500 bytes",
      // i.e. offsets 1048576-500 .. 1048575. The current implementation
      // parses an empty first part as start=0 and then treats "500" as the
      // END offset, which serves the FIRST 501 bytes instead.
      test(
          'should return last N bytes for suffix Range bytes=-500 '
          '(offsets 1048076-1048575)', () async {
        final response = await get('bytes=-500');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 1048076-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, 500);
        // Byte at offset 1048076 is 1048076 % 256 == 12
        expect(data.first, 1048076 % 256);
        // Byte at offset 1048575 is 1048575 % 256 == 255
        expect(data.last, 1048575 % 256);
      });

      test('should return last 1 byte for suffix Range bytes=-1', () async {
        final response = await get('bytes=-1');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 1048575-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, 1);
        expect(data.first, 1048575 % 256);
      });

      test(
          'should serve whole file for suffix Range larger than file '
          '(bytes=-2000000)', () async {
        // RFC 7233: a suffix length beyond the file size is clamped, the
        // whole representation is returned.
        final response = await get('bytes=-2000000');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 0-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, fileSize);
        expect(data.first, 0);
        expect(data.last, (fileSize - 1) % 256);
      });
    });

    group('multi-range Range (Bug 2)', () {
      // RFC 7233 section 3.1 / 4.1 允许服务端对多段 Range 返回 206
      // multipart/byteranges，但同时也允许忽略该 header 直接返回完整 200。
      //
      // 真实诉求：libmpv 只发单段 Range(bytes=N-) 做 seek，多段请求不会命中
      // 播放器路径。此测试只守住「不能抛未捕获异常返回 500」这条底线，
      // 不强制实现 multipart/byteranges（属于过度设计）。
      //
      // 当前实现把 "0-100,200-300" 按 '-' 切成 ['0','100,200','300']，
      // int.parse('100,200') 抛 FormatException 被外层 catch 吞掉 → 500。
      test('should not return 500 for multi-range bytes=0-100,200-300',
          () async {
        int? status;
        try {
          final response = await get('bytes=0-100,200-300');
          status = response.statusCode;
        } on DioException catch (e) {
          status = e.response?.statusCode;
        }

        // 200 / 206 / 416 都可以接受；500 不可接受，因为它意味着解析异常
        // 逃出了 handler，是崩溃而非协议响应。
        expect(status, isNotNull);
        expect(status, isNot(500),
            reason: 'multi-range request must not fail with 500');
      });
    });

    group('malformed Range (Bug 3)', () {
      // A syntactically invalid Range must never surface as 500. RFC 7233
      // section 2.1 says an unsatisfiable range gets 416, and a server is
      // explicitly allowed to ignore a malformed Range header and answer with
      // the full 200 representation. Both are acceptable; 500 is not, because
      // it means the FormatException escaped the handler.
      test('should not return 500 for malformed Range bytes=abc-def',
          () async {
        int? status;
        try {
          final response = await get('bytes=abc-def');
          status = response.statusCode;
        } on DioException catch (e) {
          status = e.response?.statusCode;
        }

        expect(status, isNotNull);
        expect(status, anyOf(200, 206, 416),
            reason: 'malformed Range must yield 200/206/416, never 500');
      });

      test('should not return 500 for non-numeric Range bytes=-xyz', () async {
        int? status;
        try {
          final response = await get('bytes=-xyz');
          status = response.statusCode;
        } on DioException catch (e) {
          status = e.response?.statusCode;
        }

        expect(status, isNotNull);
        expect(status, anyOf(200, 206, 416),
            reason: 'malformed Range must yield 200/206/416, never 500');
      });
    });

    group('end beyond file size (Bug 4)', () {
      // RFC 7233 section 2.1: "A byte-range-spec is invalid if last-byte-pos
      // is present and less than first-byte-pos" — but a last-byte-pos past
      // the end of the representation is satisfiable and MUST be clamped to
      // the current length, answered with 206.
      test('should clamp end and return 206 for bytes=0-99999999', () async {
        final response = await get('bytes=0-99999999');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 0-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, fileSize);
        expect(data.first, 0);
        expect(data.last, (fileSize - 1) % 256);
      });

      test('should clamp end for partial range bytes=1048500-99999999',
          () async {
        final response = await get('bytes=1048500-99999999');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 1048500-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, 76);
        expect(data.first, 1048500 % 256);
        expect(data.last, 1048575 % 256);
      });
    });

    // 前两个测试是边界合法请求不被误判为 416，第三个是真正的 416 语义守卫。
    // 三者在当前实现下均可通过，属于防回归用途，不是 bug 复现。
    group('boundary handling (regression guards)', () {
      // 回归守卫：请求最后一个字节是合法的，绝不能因为start > end 的
      // 判定顺序（或后续为修复 Bug 4 而加入的钳制逻辑）被误判为 416。
      test('should return last single byte for bytes=1048575-1048575',
          () async {
        final response = await get('bytes=1048575-1048575');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 1048575-1048575/1048576');

        final data = response.data as List<int>;
        expect(data.length, 1);
        expect(data.first, 1048575 % 256);
      });

      // 回归守卫：合法请求同样走 206 路径，不应被 start > end 判定误伤。
      test('should return first single byte for bytes=0-0', () async {
        final response = await get('bytes=0-0');

        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'),
            'bytes 0-0/1048576');

        final data = response.data as List<int>;
        expect(data.length, 1);
        expect(data.first, 0);
      });

      // 真正的 416 语义守卫：first-byte-pos == fileSize 已越过最后一个字节，
      // 无内容可返回。注意与 Bug 4 区分——end 越界应钳制，start 越界才 416。
      test('should return 416 for genuinely unsatisfiable bytes=1048576-',
          () async {
        // first-byte-pos == fileSize is beyond the last byte, nothing to send.
        try {
          await get('bytes=1048576-');
          fail('Should throw DioException');
        } on DioException catch (e) {
          expect(e.response?.statusCode, 416);
          expect(e.response?.headers.value('content-range'),
              'bytes */1048576');
        }
      });
    });
  });
}