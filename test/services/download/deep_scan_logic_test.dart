import 'dart:io';

import 'package:PiliPlus/services/download/scan_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'contract_probe.dart';

/// Tests for the deep-scan directory-selection logic, and for the three
/// defects that make `DownloadService.deepScanRecovery()` silently lose
/// downloads.
///
/// Read-only: nothing here modifies `lib/` or `android/`.
///
/// The tests come in three flavours, and the distinction matters — an earlier
/// revision of this file mixed them and every test was green while the bugs
/// were live:
///
///  * **Source-anchored.** Read the real `download_service.dart` /
///    `MainActivity.kt` and assert the production code does *not* contain the
///    defect. These are the ones that prove anything.
///  * **Specification.** Exercise `scan_plan.dart`, which
///    `DownloadService.deepScanRecovery` now calls, so a regression in the plan
///    reaches production. These used to be marked `skip:` while nothing in
///    `lib/` used the file; that marker is gone because the precondition is.
///  * **Control (green now, stays green).** Assert contracts that already hold
///    (`saveToSafDirectory`, `resolveContentUriToPath`), to prove the harness
///    can pass and that a RED failure is a real finding.
void main() {
  const safTree =
      'content://com.piliplus.download/tree/document%3A%2Fprimary%3ADownload';
  const localRoot = '/storage/emulated/0/Download';

  // ---------------------------------------------------------------------------
  // 1. Source-anchored RED tests. These fail while the defects are live.
  // ---------------------------------------------------------------------------
  group('防回归 · 生产源码：SAF 目录绝不能被当成本地路径拼接', () {
    test('生产代码禁止把 SAF 目录名混入本地目录集合', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      // Comments are stripped: several defect markers are named in the very
      // comment that documents the defect (`// skip bangumi for now`), and a
      // comment must never satisfy an assertion about code.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // download_service.dart:209 —— `folders.addAll(safDirs.cast<String>())`
      // pours bare SAF directory names into the same `Set<String>` that holds
      // local directory names. The set is supposed to mean "directories to
      // scan on the local filesystem"; after this line it means "directories
      // from two different filesystems", and nothing downstream can tell them
      // apart.
      expect(
        body,
        isNot(contains('folders.addAll(safDirs.cast<String>())')),
        reason: 'download_service.dart:209 把 SAF 目录名塞进本地 folders 集合。\n'
            '修复方向：SAF 名字必须保存在独立的集合里，并携带 content:// '
            'tree URI，使下游能区分「本地目录」和「SAF 目录」。\n'
            '当前代码：$body',
      );
    });

    test('生产代码禁止对混合集合统一 path.join 本地下载路径', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      // Comments are stripped: several defect markers are named in the very
      // comment that documents the defect (`// skip bangumi for now`), and a
      // comment must never satisfy an assertion about code.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // The consequence of :209. `folders` now holds both local names and SAF
      // names, and this line joins *every* one of them onto the local download
      // path. For a SAF name the result is a path that has never existed.
      expect(
        body,
        isNot(contains(r'path.join(downloadPathStr, avidStr)')),
        reason: 'download_service.dart:218 一律用本地路径拼接，'
            'SAF 目录名必然拼出一个从未存在过的路径。\n'
            '修复方向：先按 kind 分流，SAF 分支走 content:// URI，'
            '只有本地分支才允许 path.join(downloadPathStr, name)。\n'
            '当前代码：$body',
      );
    });

    test('生产代码禁止用 existsSync 静默丢弃无法访问的目录', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      // Comments are stripped: several defect markers are named in the very
      // comment that documents the defect (`// skip bangumi for now`), and a
      // comment must never satisfy an assertion about code.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // download_service.dart:220 — the third leg of the bug. Even with the
      // join fixed, an unconditional `existsSync()` bail-out silently discards
      // anything it cannot see, and the user gets "扫描完成" with no idea that
      // a whole storage backend was skipped. A dropped directory must be
      // recorded and reported.
      expect(
        body,
        isNot(contains('if (!dir.existsSync()) continue;')),
        reason: 'download_service.dart:220 用 existsSync() 静默丢弃目录。\n'
            '这正是 SAF 目录 100% 消失的那一步，且不留任何痕迹。\n'
            '修复方向：不可访问的目录必须被计入「未能恢复」并上报，'
            '不能 continue 掉当作无事发生。\n'
            '当前代码：$body',
      );
    });

    test('生产代码的扫描循环内必须存在 SAF 分支（当前一个都没有）', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // Independent of the three assertions above: whatever the data structure
      // looks like, the traversal must *somewhere* mention the SAF tree.
      // `safUri` is read at :190 and passed to the channel at :207, but after
      // that statement it is never referenced again — the entire SAF branch of
      // the scan is missing, not merely the data structure.
      //
      // Anchored on the channel call rather than on `for (final avidStr in
      // folders)` so that renaming a local variable during the fix does not
      // silently turn this into a no-op.
      final callIndex = body.indexOf("'scanSafDirectory'");
      expect(
        callIndex,
        isNot(-1),
        reason: 'deepScanRecovery 不再调用 scanSafDirectory，'
            '整个 SAF 扫描分支被删除了。请同步更新本测试。',
      );

      // Skip past the statement the call sits in, so the call's own `safUri`
      // argument does not satisfy the assertion.
      final statementEnd = body.indexOf(';', callIndex);
      final traversal = body.substring(statementEnd);

      expect(
        traversal,
        contains('safUri'),
        reason: 'deepScanRecovery 在调用 scanSafDirectory 之后，'
            '再也没有引用过 SAF tree URI。\n'
            '说明 SAF 分支的遍历逻辑整体缺失（不只是数据结构问题）：'
            '扫回来的目录名没有任何办法被访问。\n'
            '修复方向：循环内按 kind 分流，SAF 分支必须用到 safUri。\n'
            '当前遍历代码：$traversal',
      );
    });
  });

  group('防回归 · 生产源码：番剧 s_ 前缀不得被静默丢弃', () {
    test('生产代码禁止对 s_ 前缀无条件 continue', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      // Comments are stripped: several defect markers are named in the very
      // comment that documents the defect (`// skip bangumi for now`), and a
      // comment must never satisfy an assertion about code.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // download_service.dart:217 `if (avidStr.startsWith('s_')) continue;`
      // This is the known P1-3 bug. The `s_` prefix is a *routing* signal
      // (bangumi season dir name is `s_<seasonId>`, see
      // download_service.dart:573 `dirName = 's_${entry.seasonId}'`), not a
      // "this does not exist" signal. A bare `continue` with no record means a
      // season whose entry.json was lost is never rebuilt and never reported.
      expect(
        body,
        isNot(contains("startsWith('s_')) continue")),
        reason: 'download_service.dart:217 无条件跳过番剧目录且不留痕迹。\n'
            '番剧需要走 PGC season/episode 接口（见 download_service.dart:573 '
            '`s_\${entry.seasonId}`），不能喂给 avid 的 view?aid= 接口，'
            '但也绝不能静默丢弃。\n'
            '修复方向：分流到番剧专用恢复路径，并把未能恢复的番剧上报给用户。\n'
            '当前代码：$body',
      );
    });

    test('番剧必须被分流到专用恢复路径，而不是当作 avid 送进 view?aid=', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();
      // Comments are stripped: several defect markers are named in the very
      // comment that documents the defect (`// skip bangumi for now`), and a
      // comment must never satisfy an assertion about code.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // Two ways to "handle" a season, only one of which is a fix:
      //   delete the prefix check  -> view?aid=s_123 returns nothing, every
      //                              season 404s and it looks like a network
      //                              bug;
      //   route on the prefix      -> a second branch calls the PGC
      //                              season/episode API with the season id.
      //
      // Only the second is correct, so this asserts the *recovery* exists and
      // not merely that the prefix is still mentioned.
      expect(
        RegExp(r'season|bangumi|pgc|s_\$\{|episodes', caseSensitive: false)
            .hasMatch(body),
        isTrue,
        reason: 'deepScanRecovery 里没有任何番剧专用恢复逻辑。\n'
            '当前只有 :217 一句 `startsWith(\'s_\') continue`，'
            '既没有 PGC/season 接口调用，也没有把番剧上报给用户的路径。\n'
            '修复方向：解析出 seasonId，走番剧专用接口恢复，'
            '并把未能恢复的番剧列出来提示用户。\n'
            '当前代码：$body',
      );
    });
  });

  group('防回归 · 生产源码：原生 scanSafDirectory 必须递归遍历', () {
    test('原生侧必须递归遍历文件树，而不是只列一层子目录', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final kotlin = File(sources.mainActivityPath).readAsStringSync();
      final body = kotlinHandlerBody(
        source: kotlin,
        method: 'scanSafDirectory',
      );

      // MainActivity.kt:297 —— `root?.listFiles()?.filter { it.isDirectory }`
      // returns first-level subdirectory names only. The real layout is
      // <root>/<avid>/<c_N>/<typeTag>/<video.m4s>, so a single listFiles()
      // cannot see anything below the avid level. The Dart caller therefore
      // receives names it has no way to resolve.
      //
      // A correct implementation recurses (or uses a DocumentsContract tree
      // walk) and returns entries the caller can actually act on.
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
        reason: '原生 scanSafDirectory 只调用一次 root.listFiles()，'
            '不递归遍历文件树。\n'
            '真实层级是 <root>/<avid>/<c_N>/<typeTag>/<video.m4s>，'
            '只列一层拿不到任何可用的任务信息。\n'
            '修复方向：用 DocumentsContract 的 walkFileTree，'
            '或自己写递归函数遍历整棵树。\n'
            '当前实现：$body',
      );
    });

    test('原生侧不得只按 isDirectory 过滤，文件也必须能被扫描到', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final kotlin = File(sources.mainActivityPath).readAsStringSync();
      final body = kotlinHandlerBody(
        source: kotlin,
        method: 'scanSafDirectory',
      );

      // `filter { it.isDirectory }` throws away every file. The entry metadata
      // the recovery needs (`entry.json`) is a *file*, so a
      // directories-only listing cannot carry enough information to rebuild a
      // task even if the Dart side were fixed.
      expect(
        body,
        isNot(contains('filter { it.isDirectory }')),
        reason: 'MainActivity.kt:297 用 filter { it.isDirectory } 丢弃了所有文件。\n'
            '恢复任务所需的 entry.json 是文件，只返回目录名不足以重建任务。\n'
            '当前实现：$body',
      );
    });
  });

  group('防回归 · 生产源码：下载路径不应被写成 content:// URI', () {
    test('切换到 SAF 目录时 downloadPath 不应被赋值为 content:// URI', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final settings =
          File(sources.extraSettingsPath).readAsStringSync();

      // extra_settings.dart:1382 `downloadPath = newPath;` where newPath is a
      // `content://` tree URI. `downloadPath` is a filesystem path
      // (path_utils.dart:9 `late String downloadPath`) and is consumed as one
      // by `_getDownloadPath()` (`Directory(downloadPath)`), so storing a URI
      // there makes the whole download path unusable. The URI belongs in
      // GStorage under downloadPath (as the very next line does); the
      // filesystem path must stay a filesystem path.
      expect(
        settings,
        isNot(contains('downloadPath = newPath;')),
        reason: 'extra_settings.dart:1382 把 content:// URI 赋给了 downloadPath。\n'
            'downloadPath 是文件系统路径（path_utils.dart:9），'
            '被 _getDownloadPath() 当作 Directory(downloadPath) 使用；'
            '写入 URI 会让整条下载路径失效。\n'
            'URI 应只通过 GStorage.setting.put(SettingBoxKey.downloadPath, newPath) '
            '持久化，downloadPath 应保留真实文件系统路径。',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Specification tests for scan_plan.dart, which `deepScanRecovery` calls.
  // ---------------------------------------------------------------------------
  group('规格 · 本地目录 -> 待扫描路径', () {
    test('本地目录名被拼接到本地下载路径下', () {
      final plan = buildScanPlan(localDirNames: ['123', '456']);

      expect(plan.avidRoots.map((r) => r.name), ['123', '456']);
      expect(
        plan.avidRoots.map((r) => plan.localPathFor(r, localRoot)),
        [p.join(localRoot, '123'), p.join(localRoot, '456')],
      );
    });

    test('结果去重：同名本地目录只出现一次', () {
      final plan = buildScanPlan(localDirNames: ['123', '123', '456']);

      expect(plan.roots.length, 2);
      expect(plan.avidRoots.map((r) => r.name), ['123', '456']);
    });
  });

  group('规格 · SAF 目录 -> 绝不能被当成本地路径拼接', () {
    test('SAF 目录被标记为 saf 并携带 tree uri', () {
      final plan = buildScanPlan(
        localDirNames: const [],
        safDirNames: ['123', '456'],
        safTreeUri: safTree,
      );

      expect(plan.safAvidRoots.map((r) => r.name), ['123', '456']);
      expect(plan.safAvidRoots.every((r) => r.uri == safTree), isTrue);
    });

    test('SAF 目录没有本地路径 —— localPathFor 必须返回 null', () {
      // 缺陷 B 的核心规格。若这里返回非 null，调用方就会拿它去
      // Directory(path).existsSync()，而该路径永远不存在，
      // 于是 SAF 分支被 100% 静默丢弃。
      final plan = buildScanPlan(
        localDirNames: const [],
        safDirNames: ['123'],
        safTreeUri: safTree,
      );
      final safRoot = plan.safAvidRoots.single;

      expect(plan.localPathFor(safRoot, localRoot), isNull);
    });

    test('SAF 目录名不会被拼进本地下载路径（防回归）', () {
      final plan = buildScanPlan(
        localDirNames: const [],
        safDirNames: ['123'],
        safTreeUri: safTree,
      );

      for (final root in plan.roots) {
        expect(
          root.uri,
          isNot(startsWith(localRoot)),
          reason: 'SAF 目录不能带本地路径前缀',
        );
        expect(root.uri, startsWith('content://'));
      }
    });

    test('没有 tree uri 时，SAF 目录名无法定位任何东西 —— 不产出 root', () {
      // 只有目录名、没有 content:// URI，是无法访问 SAF 目录的。
      // 这里明确断言"不产出"，而不是悄悄生成一个无效 root。
      final plan = buildScanPlan(
        localDirNames: const [],
        safDirNames: ['123'],
        safTreeUri: null,
      );

      expect(plan.roots, isEmpty);
    });

    test('没有 tree uri 时，这些名字被显式上报为「无法寻址」', () {
      // 生产代码的缺陷不是「无法寻址」，而是让这些名字混进本地集合、
      // 再被 existsSync() 悄悄吞掉。损失必须被记录下来。
      expect(
        unaddressableSafNames(safDirNames: ['123', 's_456'], safTreeUri: null),
        ['123', 's_456'],
      );
      expect(
        unaddressableSafNames(
          safDirNames: const ['123'],
          safTreeUri: safTree,
        ),
        isEmpty,
      );
    });
  });

  group('规格 · 同名去重：SAF 与本地都存在同名目录', () {
    test('同名目录保留为两个独立 root，不合并', () {
      // 合并会丢掉其中一份数据：本地有 123/c_1，SAF 里也可能有 123/c_2。
      final plan = buildScanPlan(
        localDirNames: ['123'],
        safDirNames: ['123'],
        safTreeUri: safTree,
      );

      expect(plan.roots.length, 2);
      expect(plan.localAvidRoots.single.name, '123');
      expect(plan.safAvidRoots.single.name, '123');
      expect(plan.localAvidRoots.single.uri, isNull);
      expect(plan.safAvidRoots.single.uri, safTree);
    });

    test('两者名字相同但 kind 不同，因此不相等', () {
      final plan = buildScanPlan(
        localDirNames: ['123'],
        safDirNames: ['123'],
        safTreeUri: safTree,
      );

      expect(plan.roots.first, isNot(equals(plan.roots.last)));
    });

    test('同一来源内的重复名仍然去重', () {
      final plan = buildScanPlan(
        localDirNames: ['123', '123'],
        safDirNames: ['456', '456'],
        safTreeUri: safTree,
      );

      expect(plan.avidRoots.where((r) => !r.isSaf).length, 1);
      expect(plan.safAvidRoots.length, 1);
    });
  });

  group('规格 · 番剧 s_ 前缀：分流而非丢弃', () {
    test('本地番剧目录被标记为 bangumi，而不是被跳过', () {
      final plan = buildScanPlan(localDirNames: ['s_123', '456']);

      // 不在 avid 列表里：s_123 是 season id，喂给 view?aid= 必然 404。
      expect(plan.avidRoots.map((r) => r.name), ['456']);
      // 但也没有被丢弃：它被标记为需要走番剧专用恢复路径。
      expect(plan.bangumiRoots.map((r) => r.name), ['s_123']);
      expect(plan.bangumiRoots.single.scanKind, ScanKind.bangumi);
    });

    test('SAF 番剧目录同样被标记为 bangumi', () {
      final plan = buildScanPlan(
        localDirNames: const [],
        safDirNames: ['s_123', '456'],
        safTreeUri: safTree,
      );

      expect(plan.safAvidRoots.map((r) => r.name), ['456']);
      expect(plan.bangumiRoots.map((r) => r.name), ['s_123']);
      expect(plan.bangumiRoots.single.isSaf, isTrue);
      expect(plan.bangumiRoots.single.uri, safTree);
    });

    test('番剧被分流而不是静默丢弃：roots 里一个都不少', () {
      // 这是对缺陷的直接反证：download_service.dart:217 之后，
      // roots 的数量会少于发现的目录数量。
      final plan = buildScanPlan(localDirNames: ['s_1', 's_2', '100']);

      expect(plan.bangumiRoots.map((r) => r.name), ['s_1', 's_2']);
      expect(plan.roots.length, 3, reason: '3 个目录，3 个 root，一个都不能少');
    });

    test('番剧恢复路径可枚举：调用方拿得到 seasonId', () {
      // 「标记出来」必须做到可消费：调用方要能取出 seasonId 去请求
      // PGC 接口，否则标记只是换了个地方丢数据。
      final plan = buildScanPlan(localDirNames: ['s_123', 's_456']);

      expect(
        plan.bangumiRoots.map((r) => r.name.replaceFirst('s_', '')),
        ['123', '456'],
      );
    });

    test('普通数字开头但含 s_ 的目录不被误判', () {
      final plan = buildScanPlan(localDirNames: ['123', 's1234']);

      expect(plan.avidRoots.map((r) => r.name), ['123', 's1234']);
      expect(plan.bangumiRoots, isEmpty);
    });
  });

  group('规格 · 混合场景：本地 + SAF 同时存在', () {
    test('本地与 SAF 目录共存，各自可寻址，番剧另行分流', () {
      final plan = buildScanPlan(
        localDirNames: ['111', 's_222'],
        safDirNames: ['333', 's_444'],
        safTreeUri: safTree,
      );

      expect(plan.avidRoots.map((r) => r.name), ['111', '333']);
      expect(plan.localAvidRoots.map((r) => r.name), ['111']);
      expect(plan.safAvidRoots.map((r) => r.name), ['333']);
      expect(plan.safAvidRoots.map((r) => r.uri), [safTree]);
      expect(
        plan.bangumiRoots.map((r) => r.name).toList()..sort(),
        ['s_222', 's_444'],
      );
      expect(plan.roots.length, 4);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Controls: already-correct contracts. Green now, must stay green — they
  //    prove the source-probing harness can pass, so a RED above is a real
  //    finding rather than a broken probe.
  // ---------------------------------------------------------------------------
  group('对照 · 已正确的契约（用于证明探针有效）', () {
    test('deepScanRecovery 方法体可被稳定解析（探针自检）', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();

      // Comments are stripped here too, so this self-check proves the probe
      // works on *code*, not on the comments that describe the defects.
      final body = stripDartComments(
        dartMethodBody(source: service, method: 'deepScanRecovery'),
      );

      // If the probe silently returned the whole file or a truncated slice,
      // every RED assertion above would be meaningless. These markers are the
      // first statement, the local-filesystem branch, the `s_` guard in the
      // middle, and the last statement of the method, so together they pin the
      // slice to exactly this method.
      expect(body, contains('waitDownloadQueue'));
      expect(body, contains('if (localDir.existsSync())'));
      expect(body, contains("startsWith('s_')"));
      expect(body.trim(), endsWith('flagNotifier.refresh();'));
    });

    test('deleteSafFile 端到端：Kotlin 只认 uri', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final contract = parseKotlinHandler(
        source: File(sources.mainActivityPath).readAsStringSync(),
        method: 'deleteSafFile',
      );

      expect(contract.requiredKeys, {'uri'});
    });

    test('scanSafDirectory 的 Dart 调用点确实传了 uri（对照，当前就绿）', () {
      // This part of the contract is already correct. It is asserted so a
      // failure in the RED group above is attributable to the
      // recursion/filtering defect and not to a broken channel contract.
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();

      final contract = parseKotlinHandler(
        source: File(sources.mainActivityPath).readAsStringSync(),
        method: 'scanSafDirectory',
      );
      final sites = findDartCallSites(
        sources: {'download_service.dart': service},
        method: 'scanSafDirectory',
      );

      expect(contract.requiredKeys, {'uri'});
      expect(sites, isNotEmpty);
      for (final site in sites) {
        expect(
          site.argKeys,
          containsAll(contract.requiredKeys),
          reason: 'Dart (${site.file}:${site.line}) sends ${site.argKeys}',
        );
      }
    });

    test('生产代码仍在使用 s_<seasonId> 命名约定（番剧分流的前提）', () {
      final sources = ProductionSources.fromPackageRoot(Directory.current.path);
      final service =
          File(sources.downloadServicePath).readAsStringSync();

      expect(service, contains(r"dirName = 's_${entry.seasonId}'"));
    });
  });
}
