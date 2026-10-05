import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'contract_probe.dart';

/// Contract tests for `MethodChannel('com.piliplus/download')`.
///
/// The Dart and Kotlin sides of this channel are only loosely coupled: the
/// method name is a string literal on both sides, and so is every argument
/// key. Nothing fails at compile time when they drift apart. Instead the
/// native handler reads `null`, answers `INVALID_ARGS`, and the Dart caller —
/// which almost always wraps the call in a `try/catch` that only debugPrints —
/// carries on as if nothing happened.
///
/// The result is a feature that appears to work but silently does nothing:
///   * `deleteSafFile` is a no-op, so files in the SAF directory can never be
///     deleted.
///   * `scanSafDirectory` reports names that the caller then feeds into
///     `path.join(localDownloadPath, name)`, which cannot resolve to anything.
///
/// These tests pin the argument names on both sides so a mismatch fails in CI
/// rather than on a user's device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sources = ProductionSources.fromPackageRoot(Directory.current.path);
  final kotlinSource = File(sources.mainActivityPath).readAsStringSync();
  final dartSources = <String, String>{
    'download_service.dart':
        File(sources.downloadServicePath).readAsStringSync(),
    'download_manager.dart':
        File(sources.downloadManagerPath).readAsStringSync(),
  };

  late StrictKotlinDownloadChannel kotlin;

  setUp(() {
    kotlin = StrictKotlinDownloadChannel(source: kotlinSource)..install();
  });

  tearDown(() => kotlin.remove());

  /// Asserts that every Dart call site of [method] sends all the keys the
  /// Kotlin handler requires.
  ///
  /// This is the core contract assertion: a key present on the Dart side but
  /// absent from [KotlinHandlerContract.requiredKeys] is dead weight the native
  /// side never reads, and a required key the Dart side omits makes the call
  /// fail with `INVALID_ARGS` on a real device.
  void expectKeysMatch(
    String method, {
    required Map<String, String> sources,
    required String kotlinSource,
  }) {
    final contract = parseKotlinHandler(source: kotlinSource, method: method);
    final sites = findDartCallSites(sources: sources, method: method);

    expect(
      sites,
      isNotEmpty,
      reason: 'No Dart call site for "$method"; if it was removed on purpose, '
          'delete this test.',
    );

    for (final site in sites) {
      expect(
        site.argKeys,
        containsAll(contract.requiredKeys),
        reason: 'Dart/Kotlin argument-name mismatch for "$method".\n'
            'Kotlin (MainActivity.kt:${contract.line}) reads '
            '${contract.requiredKeys} and answers INVALID_ARGS when '
            '${contract.requiredKeys.length == 1 ? 'it is' : 'any of them is'} '
            'absent.\n'
            'Dart (${site.file}:${site.line}) sends ${site.argKeys}.\n'
            'Keys sent but never read by Kotlin: '
            '${site.argKeys.difference(contract.requiredKeys)}.',
      );
    }
  }

  group('deleteSafFile —— 删除 SAF 文件', () {
    test('Kotlin 侧只认 "uri" 参数名', () {
      // Pins the native contract this test enforces. If someone changes the
      // Kotlin handler, this documents it and the assertions below follow.
      final contract =
          parseKotlinHandler(source: kotlinSource, method: 'deleteSafFile');

      expect(
        contract.requiredKeys,
        {'uri'},
        reason: 'MainActivity.kt:267 reads call.argument<String>("uri") and '
            'returns result.error("INVALID_ARGS") when it is null.',
      );
    });

    test('Dart 侧必须传 "uri"，不能传 "path"', () {
      expectKeysMatch(
        'deleteSafFile',
        sources: dartSources,
        kotlinSource: kotlinSource,
      );
    });

    test('回归：记录当前实际发送的参数名（修复前应为 {"path"}）', () {
      final keys = parseDartArgKeys(
        sources: dartSources,
        method: 'deleteSafFile',
      );

      // After the fix this becomes {'uri'}. Kept as an explicit expectation so
      // the change is a deliberate, visible edit rather than a silent one.
      expect(
        keys,
        {'uri'},
        reason: 'Dart currently sends $keys. DownloadService.deleteDownload '
            '(download_service.dart:987) and deletePage (:1036) pass '
            "{'path': entryDirPath}, but MainActivity.kt:267 reads \"uri\", so "
            'the call always fails with INVALID_ARGS and SAF files can never '
            'be deleted.',
      );
    });

    test('端到端：按 Dart 实际发送的参数名调用，应被 Kotlin 接受', () async {
      final keys = parseDartArgKeys(
        sources: dartSources,
        method: 'deleteSafFile',
      );
      final args = buildArgsFor('deleteSafFile', keys);

      // The mock derives its accepted keys from the real Kotlin source, so this
      // reproduces on-device behaviour faithfully.
      await expectLater(
        () => const MethodChannel(kDownloadChannelName)
            .invokeMethod<bool>('deleteSafFile', args),
        returnsNormally,
        reason: 'Sending $args must satisfy MainActivity.kt:267. It currently '
            'fails because Dart sends "path" where Kotlin reads "uri".',
      );
    });

    test('反例：只传 "path" 必然被 Kotlin 拒绝', () async {
      // Guards the mock itself: proves the harness really does reject a
      // mismatched key, so a passing test above is meaningful.
      await expectLater(
        () => const MethodChannel(kDownloadChannelName)
            .invokeMethod<bool>('deleteSafFile', {'path': '/storage/x'}),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', kInvalidArgsCode),
        ),
      );
    });

    test('反例：只传 "uri" 必然被 Kotlin 接受', () async {
      final result = await const MethodChannel(kDownloadChannelName)
          .invokeMethod<bool>('deleteSafFile', {'uri': 'content://x'});

      expect(result, isTrue);
    });
  });

  group('scanSafDirectory —— 深度扫描 SAF 目录', () {
    test('Kotlin 侧只认 "uri" 参数名', () {
      final contract =
          parseKotlinHandler(source: kotlinSource, method: 'scanSafDirectory');

      expect(
        contract.requiredKeys,
        {'uri'},
        reason: 'MainActivity.kt:288 reads call.argument<String>("uri") and '
            'returns result.error("INVALID_ARGS", "uri is null") when null.',
      );
    });

    test('Dart 侧必须传 "uri"', () {
      expectKeysMatch(
        'scanSafDirectory',
        sources: dartSources,
        kotlinSource: kotlinSource,
      );
    });

    test('端到端：按 Dart 实际发送的参数名调用，应被 Kotlin 接受', () async {
      final keys = parseDartArgKeys(
        sources: dartSources,
        method: 'scanSafDirectory',
      );
      final args = buildArgsFor('scanSafDirectory', keys);
      kotlin.scanSafDirectoryFixture = ['123', '456'];
      // Give the recursive payload real content. The previous version left this
      // empty, so `result?['files']` was an empty map and the assertion below
      // verified nothing at all.
      kotlin.scanSafFilesFixture = {
        '123/c_0/video.m4s': 1024,
        '456/c_1/entry.json': 7,
      };
      kotlin.scanSafScannedAtFixture = 1735689600000;

      // Structured payload, not a bare name list: the scan plan needs the
      // directory names *and* the recursive file listing, because a name alone
      // cannot say whether the media underneath it survived.
      final result =
          await const MethodChannel(kDownloadChannelName)
              .invokeMapMethod<String, dynamic>('scanSafDirectory', args);

      expect(result?['dirs'], ['123', '456']);
      expect(result?['scannedAt'], 1735689600000);

      // StandardMethodCodec decodes a nested map as Map<Object?, Object?>:
      // the type arguments are erased on the wire, so
      // `isA<Map<String, dynamic>>()` can never hold across a real channel,
      // no matter what the native side sends. Assert what is actually
      // observable on the channel — and what production genuinely relies on —
      // which is stronger than the original empty-fixture type check.
      final files = result?['files'];
      expect(files, isA<Map<Object?, Object?>>());
      expect((files as Map).cast<String, int>(), {
        '123/c_0/video.m4s': 1024,
        '456/c_1/entry.json': 7,
      });
    });

    test('RED：原生侧必须递归遍历，不能只列一层子目录名', () {
      // MainActivity.kt:297 is `root?.listFiles()?.filter { it.isDirectory }`,
      // which returns first-level directory names and nothing else. The real
      // layout is <root>/<avid>/<c_N>/<typeTag>/<video.m4s>, so a single
      // listFiles() cannot expose anything the Dart side could act on.
      //
      // An earlier version of this test asserted `contains('isDirectory')` and
      // `contains('listFiles()')`, i.e. it asserted that the *defect* was
      // present. Those assertions pass forever and catch nothing.
      final body = kotlinHandlerBody(
        source: kotlinSource,
        method: 'scanSafDirectory',
      );

      expect(
        body,
        anyOf(
          contains('walkFileTree'),
          contains('listFilesRecursively'),
          contains('fun walk'),
          contains('fun scan'),
          contains('fun collect'),
          contains('fun traverse'),
        ),
        reason: '原生 scanSafDirectory 只调用一次 root.listFiles()，不递归。\n'
            '深层扫描需要递归遍历文件树才能重建任务。\n'
            '当前实现：$body',
      );
    });

    test('RED：原生侧不得丢弃文件（isDirectory 过滤会吃掉 entry.json）', () {
      // `filter { it.isDirectory }` drops every file. The metadata needed to
      // rebuild a task lives in `entry.json`, which *is* a file, so a
      // directories-only listing can never carry enough information.
      final body = kotlinHandlerBody(
        source: kotlinSource,
        method: 'scanSafDirectory',
      );

      expect(
        body,
        isNot(contains('filter { it.isDirectory }')),
        reason: '原生侧只返回目录名，文件（含 entry.json）对 Dart 完全不可见，'
            '调用方无法据此重建任务。\n'
            '当前实现：$body',
      );
    });
  });

  group('saveToSafDirectory —— 参数名一致（对照组）', () {
    test('Dart 与 Kotlin 都使用 path / targetDir', () {
      // This one is correct today. It is here as a control: it proves the
      // contract assertions can pass, so a failure above is a real regression
      // and not a broken harness.
      expectKeysMatch(
        'saveToSafDirectory',
        sources: dartSources,
        kotlinSource: kotlinSource,
      );
    });
  });

  group('resolveContentUriToPath —— 参数名一致（对照组）', () {
    test('Dart 与 Kotlin 都使用 uri', () {
      expectKeysMatch(
        'resolveContentUriToPath',
        sources: dartSources,
        kotlinSource: kotlinSource,
      );
    });
  });

  group('startDownload —— 疑似第三处参数名错配', () {
    test('Dart 与 Kotlin 的参数名一致', () {
      // Kotlin MainActivity.kt:57-58 reads "url" and "path". Dart
      // DownloadManager.startDownload (download_manager.dart:33) sends
      // {'url', 'savePath'}. Worth pinning: if the static helper is ever wired
      // up, downloads would fail with INVALID_ARGS.
      expectKeysMatch(
        'startDownload',
        sources: dartSources,
        kotlinSource: kotlinSource,
      );
    });
  });

  group('全量扫描：Dart 调用的每个方法都应与 Kotlin handler 对齐', () {
    test('不存在 Dart 调用了但 Kotlin 未注册的方法', () {
      final called = <String>{};
      for (final file in dartSources.keys) {
        called.addAll(dartMethodNamesIn(dartSources[file]!));
      }

      final unhandled = called.where((m) => !kotlinHandles(kotlinSource, m));

      expect(
        unhandled,
        isEmpty,
        reason: 'Dart calls these methods but MainActivity.kt has no handler '
            'for them. A missing handler throws MissingPluginException at '
            'runtime, which the callers swallow.',
      );
    });

    test('Dart 调用的每个方法都发送了 Kotlin 所需的全部参数名', () {
      final called = <String>{};
      for (final file in dartSources.keys) {
        called.addAll(dartMethodNamesIn(dartSources[file]!));
      }

      final mismatches = <String>[];
      for (final method in called) {
        if (!kotlinHandles(kotlinSource, method)) continue;
        final contract =
            parseKotlinHandler(source: kotlinSource, method: method);
        if (contract.requiredKeys.isEmpty) continue;
        final keys = parseDartArgKeys(sources: dartSources, method: method);
        if (!keys.containsAll(contract.requiredKeys)) {
          mismatches.add('$method: Kotlin requires ${contract.requiredKeys}, '
              'Dart sends $keys');
        }
      }

      expect(
        mismatches,
        isEmpty,
        reason: 'Argument-name mismatches between Dart and Kotlin. Each one '
            'makes the native side answer INVALID_ARGS:\n'
            '${mismatches.join('\n')}',
      );
    });
  });
}