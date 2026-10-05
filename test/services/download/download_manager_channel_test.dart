import 'dart:io';

import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'contract_probe.dart';

/// Runtime contract tests for the `DownloadManager` static wrappers.
///
/// Split out of `method_channel_contract_test.dart` on purpose: this file
/// imports `DownloadManager`, which transitively pulls in `http/init.dart` and
/// `utils/storage_pref.dart`. Those have lazy statics that read
/// `GStorage`/`Pref`, so if they ever need a Hive box opened first, the
/// failure is contained here instead of taking down the source-level contract
/// assertions.
///
/// The wrappers under test are thin: each forwards to the channel with a fixed
/// argument map and swallows errors. The tests pin the keys they forward, since
/// a silently-swallowed `PlatformException` is what makes these bugs invisible
/// in the first place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sources = ProductionSources.fromPackageRoot(Directory.current.path);
  final kotlinSource = File(sources.mainActivityPath).readAsStringSync();

  late StrictKotlinDownloadChannel kotlin;

  setUp(() {
    kotlin = StrictKotlinDownloadChannel(source: kotlinSource)..install();
  });

  tearDown(() => kotlin.remove());

  group('resolveContentUri', () {
    test('以 "uri" 参数名转发，与 MainActivity.kt:216 一致', () async {
      const uri = 'content://com.piliplus.download/tree/document%3A%2Fabc';

      final result = await DownloadManager.resolveContentUri(uri);

      expect(result, isNotNull);
      final call =
          kotlin.observedCalls.firstWhere((c) => c.method == 'resolveContentUriToPath');
      expect(
        (call.arguments as Map)['uri'],
        uri,
        reason: 'Kotlin reads call.argument<String>("uri"); sending anything '
            'else makes it answer INVALID_ARGS and this wrapper would '
            'return null via its catch-all.',
      );
    });
  });

  group('saveToSafDirectory', () {
    test('以 "path" / "targetDir" 参数名转发，与 MainActivity.kt:126-127 一致',
        () async {
      await DownloadManager.saveToSafDirectory(
        path: '/storage/emulated/0/Download/1/c_2/80/video.m4s',
        targetDir: '1/c_2/80',
      );

      final call = kotlin.observedCalls
          .firstWhere((c) => c.method == 'saveToSafDirectory');
      final args = call.arguments as Map;

      expect(
        args.keys,
        containsAll(<String>['path', 'targetDir']),
        reason: 'Kotlin reads call.argument<String>("path") and '
            'call.argument<String>("targetDir").',
      );
    });

    test('成功时返回 native 给出的 content:// uri', () async {
      final result = await DownloadManager.saveToSafDirectory(
        path: '/storage/emulated/0/Download/1/c_2/80/video.m4s',
        targetDir: '1/c_2/80',
      );

      expect(result, isNotNull);
      expect(result, contains('content://'));
    });
  });

  group('startDownload —— 已确认的第三处参数名错配', () {
    // Kotlin MainActivity.kt:57-58 reads "url" and "path":
    //     val url = call.argument<String>("url")
    //     val path = call.argument<String>("path")
    //     if (url != null && path != null) { ... } else result.error("INVALID_ARGS", ...)
    // Dart DownloadManager.startDownload (download_manager.dart:33) sends:
    //     {'url': url, 'savePath': savePath}
    // `path` is therefore always null and the download never starts. The
    // static helper has no callers in lib/ today, so this is latent rather
    // than user-visible, but the mismatch is real and worth pinning.

    test('Kotlin 侧读取 url 与 path', () {
      final contract =
          parseKotlinHandler(source: kotlinSource, method: 'startDownload');

      expect(contract.requiredKeys, containsAll(<String>['url', 'path']));
    });

    test('Dart 侧必须发送 "path"，而不是 "savePath"', () async {
      await DownloadManager.startDownload(
        'https://example.invalid/video.m4s',
        '/storage/emulated/0/Download/1/c_2/80/video.m4s',
      );

      final call = kotlin.observedCalls.firstWhere((c) => c.method == 'startDownload');
      final args = call.arguments as Map;

      expect(
        args.keys,
        contains('path'),
        reason: 'Dart sends ${args.keys.toList()}. MainActivity.kt:58 reads '
            '"path", so the key "savePath" is silently ignored and the call '
            'fails with INVALID_ARGS.',
      );
    });
  });
}
