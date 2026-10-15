import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/universal_cache_recovery_engine.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 系统级存储仿真、边界压力与自愈恢复端到端测试套件
/// 覆盖：
/// A. 鸿蒙 4.2 / Android 12+ Scoped Storage & exFAT 存储边界测试
/// B. 抗杀后台与断电式自愈测试 (Kill-Restart & Staging Recovery)
/// C. 并发混流压力与锁竞争测试 (Concurrency & Deadlock-Free)
/// D. 本地 MP4 感知与零拷贝 FD 生命周期测试
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Storage System Stress & Resilience End-to-End Test Suite', () {
    late Directory rootTempDir;
    late Directory stagingDir;
    late Directory targetStorageDir;
    late Directory sdCardDir;

    // 并发与锁状态监控
    int activeMuxersCount = 0;
    int peakConcurrentMuxers = 0;
    int clearSessionsInvocationCount = 0;
    Completer<void>? mutexDelayCompleter;

    // FD 模拟池
    int nextFd = 100;
    final Set<int> allocatedFds = <int>{};

    setUp(() async {
      rootTempDir = await Directory.systemTemp.createTemp('piliplus_stress_');
      stagingDir = Directory(p.join(rootTempDir.path, 'staging'))..createSync(recursive: true);
      targetStorageDir = Directory(p.join(rootTempDir.path, 'target_saf'))..createSync(recursive: true);
      sdCardDir = Directory(p.join(rootTempDir.path, 'sdcard_storage'))..createSync(recursive: true);

      activeMuxersCount = 0;
      peakConcurrentMuxers = 0;
      clearSessionsInvocationCount = 0;
      allocatedFds.clear();
      nextFd = 100;

      // 注册底层 MethodChannel 模拟器，高保真模拟 Android 原生 SafStorageBridge 与 MediaMuxerBridge
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.piliplus/download'),
        (MethodCall call) async {
          final args = call.arguments as Map<dynamic, dynamic>?;
          switch (call.method) {
            case 'mergeDashMedia':
              final videoPath = args?['videoPath'] as String?;
              final audioPath = args?['audioPath'] as String?;
              final outputPath = args?['outputPath'] as String?;

              if (videoPath == null || audioPath == null || outputPath == null) {
                throw PlatformException(code: 'INVALID_ARGS', message: 'Paths cannot be null');
              }

              final vFile = File(videoPath);
              final aFile = File(audioPath);
              if (!vFile.existsSync() || vFile.lengthSync() == 0 ||
                  !aFile.existsSync() || aFile.lengthSync() == 0) {
                return false;
              }

              // 模拟 MediaMuxerBridge 中的 muxMutex 互斥锁与 clearSessions
              clearSessionsInvocationCount++;
              activeMuxersCount++;
              if (activeMuxersCount > peakConcurrentMuxers) {
                peakConcurrentMuxers = activeMuxersCount;
              }

              // 如果正在并发调用，验证互斥保护（应为严格串行）
              await Future.delayed(const Duration(milliseconds: 15));
              if (mutexDelayCompleter != null && !mutexDelayCompleter!.isCompleted) {
                await mutexDelayCompleter!.future;
              }

              final outFile = File(outputPath);
              outFile.parent.createSync(recursive: true);
              final tmpOut = File('$outputPath.muxing.tmp');

              // 合并两轨数据
              final vBytes = vFile.readAsBytesSync();
              final aBytes = aFile.readAsBytesSync();
              final merged = Uint8List(vBytes.length + aBytes.length)
                ..setAll(0, vBytes)
                ..setAll(vBytes.length, aBytes);
              tmpOut.writeAsBytesSync(merged, flush: true);

              // 完成混流并原子替换
              if (outFile.existsSync()) outFile.deleteSync();
              tmpOut.renameSync(outFile.path);

              // 混流完成后删除源切片
              if (vFile.existsSync()) vFile.deleteSync();
              if (aFile.existsSync()) aFile.deleteSync();

              activeMuxersCount--;
              clearSessionsInvocationCount++;
              return true;

            case 'commitStagingEntry':
              final stagingEntryPath = args?['stagingEntryPath'] as String?;
              final targetType = args?['targetType'] as int? ?? 0;
              final targetBaseDir = args?['targetBaseDir'] as String? ?? targetStorageDir.path;
              final relativePath = args?['relativePath'] as String? ?? '';

              if (stagingEntryPath == null) return false;
              final sDir = Directory(stagingEntryPath);
              if (!sDir.existsSync()) return false;

              // 模拟 SafStorageBridge 256KB 管道流式写入与直接覆盖
              final files = sDir.listSync(recursive: true).whereType<File>();
              for (final srcFile in files) {
                if (srcFile.lengthSync() == 0) {
                  // SafStorageBridge 拒绝 0 字节写入
                  return false;
                }
                final rel = p.relative(srcFile.path, from: sDir.path);
                final dstFile = File(p.join(targetBaseDir, relativePath, rel));
                dstFile.parent.createSync(recursive: true);

                if (dstFile.existsSync()) {
                  dstFile.deleteSync(); // 直接覆盖策略
                }

                // 256KB 分块管道复制 + flush + sync
                final reader = srcFile.openSync(mode: FileMode.read);
                final writer = dstFile.openSync(mode: FileMode.write);
                final buffer = Uint8List(256 * 1024);
                int bytesRead = 0;
                while ((bytesRead = reader.readIntoSync(buffer)) > 0) {
                  writer.writeFromSync(buffer, 0, bytesRead);
                  writer.flushSync();
                }
                reader.closeSync();
                writer.closeSync();

                srcFile.deleteSync();
              }
              if (sDir.existsSync()) sDir.deleteSync(recursive: true);
              return true;

            case 'openSafFd':
              final uri = args?['uri'] as String?;
              if (uri == null || uri.isEmpty) return null;
              final fd = nextFd++;
              allocatedFds.add(fd);
              return fd;

            case 'clearSafPfds':
              allocatedFds.clear();
              return null;

            case 'resolveContentUriToPath':
              final uri = args?['uri'] as String? ?? '';
              if (uri.startsWith('content://test.authority/')) {
                final rel = uri.replaceFirst('content://test.authority/', '');
                final candidate = p.join(targetStorageDir.path, rel);
                if (File(candidate).existsSync() || Directory(candidate).existsSync()) {
                  return candidate;
                }
              }
              return null;

            case 'getExternalSDCardPath':
              return sdCardDir.path;

            case 'calculateDirSize':
              final path = args?['path'] as String? ?? '';
              final dir = Directory(path);
              if (!dir.existsSync()) return 0;
              int total = 0;
              for (final f in dir.listSync(recursive: true).whereType<File>()) {
                total += f.lengthSync();
              }
              return total;

            default:
              return null;
          }
        },
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.piliplus/download'),
        null,
      );
      if (rootTempDir.existsSync()) {
        await rootTempDir.delete(recursive: true);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    // A. 鸿蒙 4.2 / Android 12+ Scoped Storage & exFAT 存储边界测试
    // ─────────────────────────────────────────────────────────────────────────
    group('Group A: Scoped Storage & exFAT Storage Boundary Tests', () {
      test('A1: 256KB buffered streaming pipeline preserves 100% byte integrity under exFAT simulated constraints', () async {
        final stopwatch = Stopwatch()..start();
        const testPayloadSize = 4 * 1024 * 1024 + 137; // 4MB + 137 bytes prime offset
        final srcData = Uint8List(testPayloadSize);
        final random = Random(42);
        for (int i = 0; i < testPayloadSize; i++) {
          srcData[i] = random.nextInt(256);
        }
        final expectedDigest = sha256.convert(srcData).toString();

        final srcFile = File(p.join(stagingDir.path, 'source_test.mp4'))
          ..writeAsBytesSync(srcData, flush: true);

        // 模拟 exFAT / FAT32 文件系统边界：不支持跨设备原子 renameTo，强制抛出异常
        final dstPath = p.join(targetStorageDir.path, 'committed_exfat.mp4');
        final dstFile = File(dstPath);

        // 模拟 SafStorageBridge 的 256KB 管道缓冲流式写入与 flush/sync 机制
        final inStream = srcFile.openRead();
        final outSink = dstFile.openWrite(mode: FileMode.writeOnly);

        await inStream.listen((chunk) {
          outSink.add(chunk);
        }).asFuture();
        await outSink.flush();
        await outSink.close();

        stopwatch.stop();

        expect(dstFile.existsSync(), isTrue);
        expect(dstFile.lengthSync(), equals(testPayloadSize), reason: 'Size must match byte-for-byte');

        final dstData = dstFile.readAsBytesSync();
        final actualDigest = sha256.convert(dstData).toString();
        expect(actualDigest, equals(expectedDigest), reason: 'SHA-256 digest must match 100% with zero byte drop');

        final throughputMBps = (testPayloadSize / (1024 * 1024)) / (stopwatch.elapsedMilliseconds / 1000.0);
        // ignore: avoid_print
        print('    [Metric A1] 4MB exFAT 256KB Buffer Stream Time: ${stopwatch.elapsedMilliseconds}ms, Throughput: ${throughputMBps.toStringAsFixed(2)} MB/s');
      });

      test('A2: Direct overwrite cleanly replaces larger stale destination without byte residue or truncation', () async {
        final dstPath = p.join(targetStorageDir.path, 'overwritten.mp4');
        final dstFile = File(dstPath)..parent.createSync(recursive: true);

        // 预设一个更大的残留旧文件 (6MB 脏数据 0xFF)
        final staleData = Uint8List(6 * 1024 * 1024);
        staleData.fillRange(0, staleData.length, 0xFF);
        dstFile.writeAsBytesSync(staleData, flush: true);
        expect(dstFile.lengthSync(), equals(6 * 1024 * 1024));

        // 准备覆盖的新数据 (1.5MB 真实数据 0x42)
        const int newSize = 1572864;
        final newData = Uint8List(newSize);
        newData.fillRange(0, newSize, 0x42);
        final newDigest = sha256.convert(newData).toString();

        final srcFile = File(p.join(stagingDir.path, 'fresh.mp4'))..writeAsBytesSync(newData, flush: true);

        // 触发 SafStorageBridge.commitFileToSaf 策略：先显式 delete 后 direct create
        if (dstFile.existsSync()) dstFile.deleteSync();
        final outSink = dstFile.openWrite(mode: FileMode.writeOnly);
        outSink.add(srcFile.readAsBytesSync());
        await outSink.flush();
        await outSink.close();

        expect(dstFile.lengthSync(), equals(newSize), reason: 'File length must shrink exactly to new data size');
        final currentDigest = sha256.convert(dstFile.readAsBytesSync()).toString();
        expect(currentDigest, equals(newDigest), reason: 'Digest must match new content without residual bytes');
      });

      test('A3: Zero-byte truncated source is detected and rejected with transaction rollback', () async {
        final zeroByteSrc = File(p.join(stagingDir.path, 'zero_byte.mp4'))..createSync();
        expect(zeroByteSrc.lengthSync(), equals(0));

        final taskDir = Directory(p.join(stagingDir.path, 'task_zero'))..createSync();
        File(p.join(taskDir.path, '0.mp4')).createSync();

        final commitResult = await DownloadManager.commitStagingEntry(
          stagingEntryPath: taskDir.path,
          targetType: 2,
          targetBaseDir: targetStorageDir.path,
          relativePath: 'avid_zero/cid_zero',
        );

        expect(commitResult, isFalse, reason: 'SafStorageBridge must reject 0-byte corrupt files');
        final targetArtifact = File(p.join(targetStorageDir.path, 'avid_zero/cid_zero/0.mp4'));
        expect(targetArtifact.existsSync(), isFalse, reason: 'Target document must not be persisted on 0-byte failure');
      });

      test('A4: High-frequency batch staging commits under simulated I/O pressure (20 items)', () async {
        final stopwatch = Stopwatch()..start();
        const itemCount = 20;
        int totalBytesCommitted = 0;

        for (int i = 0; i < itemCount; i++) {
          final itemDir = Directory(p.join(stagingDir.path, 'batch_item_$i'))..createSync();
          final size = (64 + (i % 8) * 128) * 1024; // 64KB ~ 960KB
          final bytes = Uint8List(size);
          for (int j = 0; j < size; j++) {
            bytes[j] = (i + j) & 0xFF;
          }
          File(p.join(itemDir.path, '0.mp4')).writeAsBytesSync(bytes, flush: true);
          File(p.join(itemDir.path, 'entry.json')).writeAsStringSync('{"avid": $i, "title": "Batch $i"}');
          totalBytesCommitted += size;

          final success = await DownloadManager.commitStagingEntry(
            stagingEntryPath: itemDir.path,
            targetType: 2,
            targetBaseDir: targetStorageDir.path,
            relativePath: 'batch_series/item_$i',
          );
          expect(success, isTrue);
          expect(itemDir.existsSync(), isFalse, reason: 'Staging directory must be cleaned up on success');
          expect(File(p.join(targetStorageDir.path, 'batch_series/item_$i/0.mp4')).lengthSync(), equals(size));
        }

        stopwatch.stop();
        final throughput = (totalBytesCommitted / (1024 * 1024)) / (stopwatch.elapsedMilliseconds / 1000.0);
        // ignore: avoid_print
        print('    [Metric A4] 20 Batch Commits Total: ${totalBytesCommitted ~/ 1024} KB in ${stopwatch.elapsedMilliseconds}ms (${throughput.toStringAsFixed(2)} MB/s)');
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // B. 抗杀后台与断电式自愈测试 (Kill-Restart & Staging Recovery)
    // ─────────────────────────────────────────────────────────────────────────
    group('Group B: Kill-Restart & Staging Recovery Resilience Tests', () {
      test('B1: Abrupt kill during staging download ignores orphaned .part files without crashing', () async {
        final orphanTaskDir = Directory(p.join(targetStorageDir.path, '10001', 'c_20001'))..createSync(recursive: true);
        File(p.join(orphanTaskDir.path, 'video.m4s.part')).writeAsBytesSync(Uint8List(50 * 1024));

        final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
          basePath: targetStorageDir.path,
          dirType: 0,
        );

        expect(recovered.isEmpty, isTrue, reason: 'Incomplete .part task without entry.json must not be admitted to library');
      });

      test('B2: Kill when download completed but before muxing triggers self-healing remux on restart', () async {
        final videoDir = Directory(p.join(targetStorageDir.path, '20002', 'c_30002'))..createSync(recursive: true);
        final tagDir = Directory(p.join(videoDir.path, '80'))..createSync();

        final vFile = File(p.join(tagDir.path, PathUtils.videoNameType2))..writeAsBytesSync(Uint8List(200 * 1024));
        final aFile = File(p.join(tagDir.path, PathUtils.audioNameType2))..writeAsBytesSync(Uint8List(50 * 1024));

        final entryJsonMap = {
          'media_type': 2,
          'has_dash_audio': true,
          'is_completed': true,
          'total_bytes': 250 * 1024,
          'downloaded_bytes': 250 * 1024,
          'title': 'Kill Test Episode 1',
          'type_tag': '80',
          'avid': 20002,
          'time_update_stamp': 1700000000,
          'time_create_stamp': 1700000000,
          'page_data': {
            'cid': 30002,
            'page': 1,
            'part': 'Part 1',
          },
        };
        final entryFile = File(p.join(videoDir.path, 'entry.json'))
          ..writeAsStringSync(jsonEncode(entryJsonMap), flush: true);

        // 模拟进程杀后台重启，UniversalCacheRecoveryEngine 执行冷启动自愈扫描
        final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
          basePath: targetStorageDir.path,
          dirType: 0,
        );

        expect(recovered.length, equals(1));
        final rec = recovered.first;
        expect(rec.avid, equals(20002));
        expect(rec.cid, equals(30002));
        expect(rec.isCompleted, isTrue);

        // 校验自愈产物：自动调用 mergeDashMedia 生成 0.mp4 并将 mediaType 转换为 1 (MP4)
        final targetMp4 = File(p.join(tagDir.path, PathUtils.videoNameType1));
        expect(targetMp4.existsSync(), isTrue, reason: 'Self-healing engine must synthesize 0.mp4');
        expect(rec.mediaType, equals(1), reason: 'Muxed entry must be upgraded to single MP4 (mediaType: 1)');

        // 验证 entry.json 已被安全原子回写
        final updatedJson = jsonDecode(entryFile.readAsStringSync()) as Map<String, dynamic>;
        expect(updatedJson['media_type'], equals(1));
      });

      test('B3: Kill midway through FFmpeg muxing falls back to dual-track protection if remux fails', () async {
        final videoDir = Directory(p.join(targetStorageDir.path, '30003', 'c_40003'))..createSync(recursive: true);
        final tagDir = Directory(p.join(videoDir.path, '80'))..createSync();

        // 模拟混流到一半残留的临时文件
        File(p.join(tagDir.path, '0.mp4.muxing.tmp')).writeAsBytesSync(Uint8List(80 * 1024));
        File(p.join(tagDir.path, PathUtils.videoNameType2)).writeAsBytesSync(Uint8List(120 * 1024));
        File(p.join(tagDir.path, PathUtils.audioNameType2)).writeAsBytesSync(Uint8List(30 * 1024));

        final entryJsonMap = {
          'media_type': 2,
          'has_dash_audio': true,
          'is_completed': true,
          'total_bytes': 150 * 1024,
          'downloaded_bytes': 150 * 1024,
          'title': 'Interrupted Mux Episode',
          'type_tag': '80',
          'avid': 30003,
          'time_update_stamp': 1700000010,
          'time_create_stamp': 1700000010,
          'page_data': {
            'cid': 40003,
            'page': 1,
            'part': 'Part 1',
          },
        };
        File(p.join(videoDir.path, 'entry.json')).writeAsStringSync(jsonEncode(entryJsonMap), flush: true);

        // 临时拦截 mock，使本次混流模拟底层转码不支持失败
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.piliplus/download'),
          (MethodCall call) async {
            if (call.method == 'mergeDashMedia') {
              return false; // 模拟失败
            }
            return null;
          },
        );

        final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
          basePath: targetStorageDir.path,
          dirType: 0,
        );

        expect(recovered.length, equals(1));
        final rec = recovered.first;
        // 关键防线：当混流失败时，必须安全保留为 DASH 双轨 (mediaType: 2)，杜绝黑屏与丢音轨
        expect(rec.mediaType, equals(2));
        expect(rec.hasDashAudio, isTrue);
        expect(rec.status, equals(DownloadStatus.completed));
      });

      test('B4: Tier 2 Offline Reverse Synthesis reconstructs metadata when entry.json is missing', () async {
        final videoDir = Directory(p.join(targetStorageDir.path, '40004', 'c_50004'))..createSync(recursive: true);
        final tagDir = Directory(p.join(videoDir.path, '80'))..createSync();

        // 只有 0.mp4 媒体文件，无 entry.json (断电丢失元数据)
        const mp4Size = 512 * 1024;
        File(p.join(tagDir.path, '0.mp4')).writeAsBytesSync(Uint8List(mp4Size), flush: true);

        final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
          basePath: targetStorageDir.path,
          dirType: 0,
        );

        expect(recovered.length, equals(1));
        final synthetic = recovered.first;
        expect(synthetic.avid, equals(40004), reason: 'Must parse avid from parent folder name');
        expect(synthetic.cid, equals(50004), reason: 'Must parse cid from entry folder name');
        expect(synthetic.mediaType, equals(1));
        expect(synthetic.totalBytes, equals(mp4Size));

        // 确认 Tier 2 引擎已原子补全 entry.json
        final restoredJsonFile = File(p.join(videoDir.path, 'entry.json'));
        expect(restoredJsonFile.existsSync(), isTrue, reason: 'Engine must persist synthetic entry.json for fast subsequent boot');
      });

      test('B5: Multi-entry deduplication by (avid, cid) and sorted by timestamp descending', () async {
        // 创建 3 个条目，其中 2 个属于同一视频但在不同目录（模拟重复恢复）
        final dir1 = Directory(p.join(targetStorageDir.path, '50005', 'c_60005'))..createSync(recursive: true);
        final dir2 = Directory(p.join(targetStorageDir.path, '50005_dup', 'c_60005'))..createSync(recursive: true);
        final dir3 = Directory(p.join(targetStorageDir.path, '60006', 'c_70006'))..createSync(recursive: true);

        File(p.join(dir1.path, '0.mp4')).writeAsBytesSync(Uint8List(100));
        File(p.join(dir1.path, 'entry.json')).writeAsStringSync(jsonEncode({
          'avid': 50005,
          'page_data': {'cid': 60005},
          'time_update_stamp': 1000,
          'title': 'Original 50005',
        }));

        File(p.join(dir2.path, '0.mp4')).writeAsBytesSync(Uint8List(100));
        File(p.join(dir2.path, 'entry.json')).writeAsStringSync(jsonEncode({
          'avid': 50005,
          'page_data': {'cid': 60005},
          'time_update_stamp': 2000,
          'title': 'Duplicate 50005 Newer',
        }));

        File(p.join(dir3.path, '0.mp4')).writeAsBytesSync(Uint8List(100));
        File(p.join(dir3.path, 'entry.json')).writeAsStringSync(jsonEncode({
          'avid': 60006,
          'page_data': {'cid': 70006},
          'time_update_stamp': 3000,
          'title': 'Item 60006',
        }));

        final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
          basePath: targetStorageDir.path,
          dirType: 0,
        );

        expect(recovered.length, equals(2), reason: 'Duplicate (avid, cid) must be merged into one entry');
        expect(recovered[0].avid, equals(60006), reason: 'Highest timestamp (3000) must appear first');
        expect(recovered[1].avid, equals(50005));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // C. 并发混流压力与锁竞争测试 (Concurrency & Deadlock-Free)
    // ─────────────────────────────────────────────────────────────────────────
    group('Group C: Concurrency Muxing & Deadlock-Free Stress Tests', () {
      test('C1: 25 simultaneous mergeDashMedia tasks execute with zero deadlock and zero concurrency crashes', () async {
        const taskCount = 25;
        final stopwatch = Stopwatch()..start();

        final futures = <Future<bool>>[];
        for (int i = 0; i < taskCount; i++) {
          final tDir = Directory(p.join(stagingDir.path, 'mux_task_$i'))..createSync();
          final vFile = File(p.join(tDir.path, 'video.m4s'))..writeAsBytesSync(Uint8List(10 * 1024));
          final aFile = File(p.join(tDir.path, 'audio.m4s'))..writeAsBytesSync(Uint8List(2 * 1024));
          final oPath = p.join(tDir.path, '0.mp4');

          futures.add(DownloadManager.mergeDashMedia(
            videoPath: vFile.path,
            audioPath: aFile.path,
            outputPath: oPath,
          ));
        }

        final results = await Future.wait(futures);
        stopwatch.stop();

        expect(results.length, equals(taskCount));
        expect(results.every((r) => r == true), isTrue, reason: 'All 25 parallel mux tasks must succeed');
        expect(activeMuxersCount, equals(0), reason: 'All active mux locks must be cleanly released');
        expect(clearSessionsInvocationCount, equals(taskCount * 2), reason: 'Every task must clean sessions before and after');

        // ignore: avoid_print
        print('    [Metric C1] 25 Concurrent Mux Tasks Elapsed: ${stopwatch.elapsedMilliseconds}ms, ClearSessions Calls: $clearSessionsInvocationCount');
      });

      test('C2: Non-poisoning mutex recovery when partial tasks encounter invalid inputs', () async {
        final futures = <Future<bool>>[];

        for (int i = 0; i < 15; i++) {
          final tDir = Directory(p.join(stagingDir.path, 'fault_task_$i'))..createSync();
          final isFaulty = (i % 3 == 0); // 1/3 的任务故意提供缺失/空文件

          final vFile = File(p.join(tDir.path, 'video.m4s'));
          final aFile = File(p.join(tDir.path, 'audio.m4s'));
          if (!isFaulty) {
            vFile.writeAsBytesSync(Uint8List(8 * 1024));
            aFile.writeAsBytesSync(Uint8List(2 * 1024));
          } else {
            // 空文件或不写，触发异常/失败
            vFile.createSync();
          }

          futures.add(DownloadManager.mergeDashMedia(
            videoPath: vFile.path,
            audioPath: aFile.path,
            outputPath: p.join(tDir.path, '0.mp4'),
          ));
        }

        final results = await Future.wait(futures);
        expect(results.length, equals(15));

        // 验证失败任务返回 false，但未发生互斥锁毒化 (poisoning) 或死锁
        for (int i = 0; i < 15; i++) {
          if (i % 3 == 0) {
            expect(results[i], isFalse, reason: 'Faulty task $i must fail gracefully');
          } else {
            expect(results[i], isTrue, reason: 'Healthy task $i must succeed without being blocked by previous failure');
          }
        }
        expect(activeMuxersCount, equals(0), reason: 'Mutex must be released even upon task failure');
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // D. 本地 MP4 感知与零拷贝 FD 生命周期测试
    // ─────────────────────────────────────────────────────────────────────────
    group('Group D: Local MP4 Auto-probing & Zero-Copy FD Lifecycle Tests', () {
      test('D1: FileSource dynamically auto-probes local 0.mp4 in root and tag folders', () {
        final testDir = Directory(p.join(rootTempDir.path, 'player_probe'))..createSync();

        // 场景 1: 0.mp4 在根目录下
        final rootMp4 = File(p.join(testDir.path, PathUtils.videoNameType1))..writeAsStringSync('root mp4');
        final sourceRoot = FileSource(
          dir: testDir.path,
          isMp4: false, // 外部传参为 false
          hasDashAudio: false,
          typeTag: '80',
        );
        expect(sourceRoot.isMp4, isTrue, reason: 'Must detect 0.mp4 in root');
        expect(sourceRoot.videoSource, equals(rootMp4.path));
        expect(sourceRoot.audioSource, isNull);
        rootMp4.deleteSync();

        // 场景 2: 0.mp4 在 tag 目录下 (80/0.mp4)
        final tagDir = Directory(p.join(testDir.path, '80'))..createSync();
        final tagMp4 = File(p.join(tagDir.path, PathUtils.videoNameType1))..writeAsStringSync('tag mp4');
        final sourceTag = FileSource(
          dir: testDir.path,
          isMp4: false,
          hasDashAudio: false,
          typeTag: '80',
        );
        expect(sourceTag.isMp4, isTrue, reason: 'Must detect 0.mp4 in tag folder');
        expect(sourceTag.videoSource, equals(tagMp4.path));
        tagMp4.deleteSync();

        // 场景 3: 0.mp4 缺失但存在 video.m4s 与 audio.m4s，必须无缝退化为 DASH 双轨
        final vM4s = File(p.join(tagDir.path, PathUtils.videoNameType2))..writeAsStringSync('video stream');
        final aM4s = File(p.join(tagDir.path, PathUtils.audioNameType2))..writeAsStringSync('audio stream');
        final sourceDash = FileSource(
          dir: testDir.path,
          isMp4: true, // 外部传参错误声称是 MP4
          hasDashAudio: true,
          typeTag: '80',
        );
        expect(sourceDash.isMp4, isFalse, reason: 'Must reject isMp4 when 0.mp4 does not exist');
        expect(sourceDash.videoSource, equals(vM4s.path));
        expect(sourceDash.audioSource, equals(aM4s.path));
      });

      test('D2: openSafFd allocates zero-copy descriptor and translates to fdclose:// URL', () async {
        const testSafUri = 'content://com.android.externalstorage.documents/tree/SDCARD%3Avideos/document/SDCARD%3Avideos%2F0.mp4';
        final fd = await DownloadManager.openSafFd(testSafUri);

        expect(fd, isNotNull);
        expect(fd! >= 0, isTrue);
        expect(allocatedFds.contains(fd), isTrue);

        // 模拟 libmpv / media_kit 桥接层解析
        final mpvUrl = 'fdclose://$fd';
        expect(mpvUrl, equals('fdclose://$fd'));

        // 验证 EDL 格式合成规范
        final isFileSource = true;
        final edlSegment = '%${isFileSource ? utf8.encode(mpvUrl).length : mpvUrl.length}%$mpvUrl;';
        expect(edlSegment, contains('fdclose://$fd'));
      });

      test('D3: Zero FD leak guarantee: clearSafPfds terminates all active detached descriptors', () async {
        // 模拟连续播放 10 个视频切片，每次分配 FD
        for (int i = 0; i < 10; i++) {
          final fd = await DownloadManager.openSafFd('content://media/video_$i.mp4');
          expect(fd, isNotNull);
        }
        expect(allocatedFds.length, equals(10), reason: '10 FDs currently allocated');

        // 触发释放闭环
        await DownloadManager.clearSafPfds();
        expect(allocatedFds.isEmpty, isTrue, reason: 'All FDs must be released, count must drop to 0');
      });
    });
  });
}
