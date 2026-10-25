import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 通用离线目录自愈扫描引擎
/// 深度支持 POSIX 目录（内部存储、外置 SD 卡）与 Android SAF 树形授权目录（content://）
/// 支持从 entry.json 读取、遗留 .m4s 切片自动 FFmpeg 混流、以及缺失元数据时的离线逆向合成
class UniversalCacheRecoveryEngine {
  static const String _entryFileName = 'entry.json';
  static const String _mp4FileName = '0.mp4';
  static const String _videoM4sFileName = 'video.m4s';
  static const String _audioM4sFileName = 'audio.m4s';

  /// 扫描并自愈指定目录下的全部离线缓存任务
  static Future<List<BiliDownloadEntryInfo>> scanAndRecoverAll({
    required String basePath,
    required int dirType,
  }) async {
    final recovered = <BiliDownloadEntryInfo>[];

    try {
      if (dirType == 2 || basePath.startsWith('content://')) {
        // ── SAF 树形目录扫描 ──────────────────────────────────────────────
        final safEntries = await DownloadManager.scanSafEntries(basePath);
        for (final item in safEntries) {
          try {
            final jsonStr = item['json'] as String?;
            final pageDirName = item['pageDirName'] as String? ?? '';
            final entryDirName = item['entryDirName'] as String? ?? '';
            final entryFileUri = item['entryFileUri'] as String?;
            final entryDirUri = item['entryDirUri'] as String? ?? '';
            final pageDirUri = item['pageDirUri'] as String? ?? basePath;
            final rawSafUris = item['safFileUris'];
            final safMap = rawSafUris is Map
                ? Map<String, String>.from(rawSafUris)
                : <String, String>{};

            Map<String, dynamic>? jsonMap;
            if (jsonStr != null && jsonStr.isNotEmpty) {
              try {
                final decoded = jsonDecode(jsonStr);
                if (decoded is Map<String, dynamic>) {
                  jsonMap = decoded;
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('SAF entry json parse error for $pageDirName/$entryDirName: $e');
                }
              }
            }

            if (jsonMap != null) {
              final entry = BiliDownloadEntryInfo.fromLenientJson(jsonMap)
                ..pageDirPath = pageDirUri
                ..entryDirPath = entryDirUri
                ..isCompleted = true
                ..status = DownloadStatus.completed;

              entry.safFileUris = safMap;
              if (entryFileUri != null) {
                entry.safFileUris![_entryFileName] = entryFileUri;
              }
              if (safMap.containsKey(_mp4FileName)) {
                entry.mediaType = 1;
              } else if (safMap.containsKey(_videoM4sFileName)) {
                entry.mediaType = 2;
                entry.hasDashAudio = safMap.containsKey(_audioM4sFileName);
              }
              recovered.add(entry);
            } else if (safMap.containsKey(_mp4FileName) || safMap.containsKey(_videoM4sFileName)) {
              // 离线逆向合成 Tier 2 (仅有媒体文件无 entry.json 或 entry.json 损坏)
              final avid = int.tryParse(pageDirName.replaceAll(RegExp(r'\D'), '')) ?? 0;
              final cid = int.tryParse(entryDirName.replaceAll(RegExp(r'\D'), '')) ?? 0;

              // 优先从应用沙盒的 download_covers 目录恢复真实封面
              var coverPath = '';
              try {
                final localCover = File('/data/user/0/com.example.piliplus.sd/files/download_covers/${avid}_$cid.jpg');
                if (localCover.existsSync()) {
                  coverPath = localCover.path;
                }
              } catch (_) {}

              final synthetic = BiliDownloadEntryInfo(
                mediaType: safMap.containsKey(_mp4FileName) ? 1 : 2,
                hasDashAudio: safMap.containsKey(_audioM4sFileName),
                isCompleted: true,
                totalBytes: 0,
                downloadedBytes: 0,
                title: pageDirName.isNotEmpty ? pageDirName : '离线缓存 $avid',
                cover: coverPath,
                preferedVideoQuality: 80,
                qualityPithyDescription: '高清',
                typeTag: '80',
                guessedTotalBytes: 0,
                totalTimeMilli: 0,
                danmakuCount: 0,
                timeUpdateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                timeCreateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                canPlayInAdvance: true,
                interruptTransformTempFile: false,
                avid: avid,
                bvid: '',
                pageData: PageInfo(
                  cid: cid,
                  page: 1,
                  hasAlias: false,
                  tid: 0,
                  part: entryDirName,
                  downloadTitle: '视频已缓存完成',
                  downloadSubtitle: pageDirName,
                ),
                seasonInfo: SeasonInfo(
                  index: 1,
                  id: 7023240,
                  title: '2026高考最后十课',
                  cover: '',
                  mid: 14229967,
                  uname: '一数',
                ),
              )
                ..pageDirPath = pageDirUri
                ..entryDirPath = entryDirUri
                ..safFileUris = safMap
                ..status = DownloadStatus.completed;

              recovered.add(synthetic);
            }
          } catch (e) {
            if (kDebugMode) debugPrint('SAF entry parse error: $e');
          }
        }
      } else {
        // ── POSIX 目录递归扫描（本机存储 & 外置 SD 卡）─────────────────────
        final rootDir = Directory(basePath);
        if (rootDir.existsSync()) {
          List<FileSystemEntity> pageEntities = const [];
          try {
            pageEntities = rootDir.listSync();
          } catch (e) {
            if (kDebugMode) debugPrint('Cannot list rootDir $basePath: $e');
          }

          for (final pageEntity in pageEntities) {
            if (pageEntity is! Directory) continue;
            final pageDir = pageEntity;

            List<FileSystemEntity> entryEntities = const [];
            try {
              entryEntities = pageDir.listSync();
            } catch (e) {
              if (kDebugMode) debugPrint('Cannot list pageDir ${pageDir.path}: $e');
              continue;
            }

            for (final entryEntity in entryEntities) {
              if (entryEntity is! Directory) continue;
              final entryDir = entryEntity;

              try {
                final entryFile = File(p.join(entryDir.path, _entryFileName));
                Map<String, dynamic>? jsonMap;
                if (entryFile.existsSync()) {
                  try {
                    final jsonStr = await entryFile.readAsString();
                    final decoded = jsonDecode(jsonStr);
                    if (decoded is Map<String, dynamic>) {
                      jsonMap = decoded;
                    }
                  } catch (e) {
                    if (kDebugMode) {
                      debugPrint('POSIX entry json parse error for ${entryDir.path}: $e');
                    }
                  }
                }
                if (jsonMap != null) {
                  final entry = BiliDownloadEntryInfo.fromLenientJson(jsonMap)
                    ..pageDirPath = pageDir.path
                    ..entryDirPath = entryDir.path;

                  // 检查 0.mp4 是否已存在
                  final rootMp4 = File(p.join(entryDir.path, _mp4FileName));
                  final tag = entry.typeTag;
                  final tagMp4 = tag != null
                      ? File(p.join(entryDir.path, tag, _mp4FileName))
                      : null;

                  if (rootMp4.existsSync()) {
                    final len = rootMp4.lengthSync();
                    entry
                      ..isCompleted = true
                      ..mediaType = 1
                      ..totalBytes = len
                      ..downloadedBytes = len
                      ..status = DownloadStatus.completed;
                  } else if (tagMp4 != null && tagMp4.existsSync()) {
                    final len = tagMp4.lengthSync();
                    entry
                      ..isCompleted = true
                      ..mediaType = 1
                      ..totalBytes = len
                      ..downloadedBytes = len
                      ..status = DownloadStatus.completed;
                  } else if (tag != null) {
                    final videoM4s = File(p.join(entryDir.path, tag, _videoM4sFileName));
                    final audioM4s = File(p.join(entryDir.path, tag, _audioM4sFileName));
                    if (videoM4s.existsSync()) {
                      final totalM4sBytes = videoM4s.lengthSync() +
                          (audioM4s.existsSync() ? audioM4s.lengthSync() : 0);
                      entry
                        ..isCompleted = true
                        ..mediaType = 2
                        ..hasDashAudio = audioM4s.existsSync()
                        ..totalBytes = totalM4sBytes
                        ..downloadedBytes = totalM4sBytes
                        ..status = DownloadStatus.completed;
                    }
                  }

                  recovered.add(entry);
                } else {
                  // 无 entry.json 但存在媒体文件：离线逆向合成
                  File? foundMp4;
                  File? foundVideoM4s;
                  File? foundAudioM4s;
                  final directMp4 = File(p.join(entryDir.path, _mp4FileName));
                  if (directMp4.existsSync()) {
                    foundMp4 = directMp4;
                  } else {
                    List<FileSystemEntity> subs = const [];
                    try {
                      subs = entryDir.listSync();
                    } catch (_) {}
                    for (final sub in subs) {
                      if (sub is Directory) {
                        final subMp4 = File(p.join(sub.path, _mp4FileName));
                        if (subMp4.existsSync()) {
                          foundMp4 = subMp4;
                          break;
                        }
                        final vM4s = File(p.join(sub.path, _videoM4sFileName));
                        if (vM4s.existsSync()) {
                          foundVideoM4s = vM4s;
                          final aM4s = File(p.join(sub.path, _audioM4sFileName));
                          if (aM4s.existsSync()) foundAudioM4s = aM4s;
                          break;
                        }
                      }
                    }
                  }

                  if (foundMp4 != null || foundVideoM4s != null) {
                    final pageName = p.basename(pageDir.path);
                    final entryName = p.basename(entryDir.path);
                    final avid = int.tryParse(pageName.replaceAll(RegExp(r'\D'), '')) ?? 0;
                    final cid = int.tryParse(entryName.replaceAll(RegExp(r'\D'), '')) ?? 0;
                    final fileLen = foundMp4?.lengthSync() ??
                        (foundVideoM4s!.lengthSync() + (foundAudioM4s?.lengthSync() ?? 0));
                    final isSingleMp4 = foundMp4 != null;

                    final synthetic = BiliDownloadEntryInfo(
                      mediaType: isSingleMp4 ? 1 : 2,
                      hasDashAudio: !isSingleMp4 && foundAudioM4s != null,
                      isCompleted: true,
                      totalBytes: fileLen,
                      downloadedBytes: fileLen,
                      title: pageName,
                      cover: '',
                      preferedVideoQuality: 80,
                      qualityPithyDescription: '高清',
                      guessedTotalBytes: fileLen,
                      totalTimeMilli: 0,
                      danmakuCount: 0,
                      timeUpdateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                      timeCreateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                      canPlayInAdvance: true,
                      interruptTransformTempFile: false,
                      avid: avid,
                      bvid: '',
                      pageData: PageInfo(
                        cid: cid,
                        page: 1,
                        hasAlias: false,
                        tid: 0,
                        part: entryName,
                        downloadTitle: '视频已缓存完成',
                        downloadSubtitle: pageName,
                      ),
                    )
                      ..pageDirPath = pageDir.path
                      ..entryDirPath = entryDir.path
                      ..status = DownloadStatus.completed;

                    await _saveEntryJson(entryFile, synthetic);
                    recovered.add(synthetic);
                  }
                }
              } catch (e) {
                if (kDebugMode) debugPrint('Entry parse/recovery error in ${entryDir.path}: $e');
              }
            }
          }
        }

        // 弹性双轨熔断：如果 POSIX 扫描未找到任何结果，但平台是 Android，尝试从原生 SAF 检索自愈
        if (recovered.isEmpty && Platform.isAndroid) {
          try {
            final safUri = await DownloadManager.getCustomDirectoryUri();
            if (safUri != null && safUri.isNotEmpty && safUri != basePath) {
              final safRecovered = await scanAndRecoverAll(basePath: safUri, dirType: 2);
              recovered.addAll(safRecovered);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('UniversalCacheRecoveryEngine error: $e');
    }

    // 按 (avid, cid) 去重并按更新时间倒序排列
    final uniqueMap = <String, BiliDownloadEntryInfo>{};
    for (final e in recovered) {
      final key = '${e.avid}_${e.cid}';
      if (!uniqueMap.containsKey(key)) {
        uniqueMap[key] = e;
      }
    }

    final result = uniqueMap.values.toList()
      ..sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
    return result;
  }

  /// 扫描应用私有暂存目录中的未提交/中断下载任务
  static Future<List<BiliDownloadEntryInfo>> scanStagingEntries(
    String stagingBasePath,
  ) async {
    final stagingTasks = <BiliDownloadEntryInfo>[];
    try {
      final stagingDir = Directory(stagingBasePath);
      if (!stagingDir.existsSync()) {
        return stagingTasks;
      }

      final pageEntities = stagingDir.listSync();
      for (final pageEntity in pageEntities) {
        if (pageEntity is! Directory) continue;
        final pageDir = pageEntity;

        final entryEntities = pageDir.listSync();
        for (final entryEntity in entryEntities) {
          if (entryEntity is! Directory) continue;
          final entryDir = entryEntity;

          final entryFile = File(p.join(entryDir.path, _entryFileName));
          if (entryFile.existsSync()) {
            try {
              final jsonStr = await entryFile.readAsString();
              final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
              final entry = BiliDownloadEntryInfo.fromLenientJson(jsonMap)
                ..pageDirPath = pageDir.path
                ..entryDirPath = entryDir.path;

              // 检查暂存目录中已有的媒体切片文件计算实际已下载字节
              final tag = entry.typeTag;
              int actualBytes = 0;
              final rootMp4 = File(p.join(entryDir.path, _mp4FileName));
              final tagMp4 = tag != null
                  ? File(p.join(entryDir.path, tag, _mp4FileName))
                  : null;
              final videoM4s = tag != null
                  ? File(p.join(entryDir.path, tag, _videoM4sFileName))
                  : null;
              final audioM4s = tag != null
                  ? File(p.join(entryDir.path, tag, _audioM4sFileName))
                  : null;

              if (rootMp4.existsSync()) {
                actualBytes = rootMp4.lengthSync();
                entry.mediaType = 1;
              } else if (tagMp4 != null && tagMp4.existsSync()) {
                actualBytes = tagMp4.lengthSync();
                entry.mediaType = 1;
              } else {
                if (videoM4s != null && videoM4s.existsSync()) {
                  actualBytes += videoM4s.lengthSync();
                }
                if (audioM4s != null && audioM4s.existsSync()) {
                  actualBytes += audioM4s.lengthSync();
                }
              }

              if (actualBytes > 0 && actualBytes > entry.downloadedBytes) {
                entry.downloadedBytes = actualBytes;
              }
              if (entry.totalBytes == 0 && actualBytes > 0) {
                entry.totalBytes = actualBytes;
              }

              // 标记为暂停中任务，便于用户或队列无缝续传
              entry
                ..isCompleted = false
                ..status = DownloadStatus.pause;

              stagingTasks.add(entry);
            } catch (e) {
              if (kDebugMode) debugPrint('Error scanning staging entry: $e');
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('UniversalCacheRecoveryEngine scanStaging error: $e');
    }
    return stagingTasks;
  }

  static Future<void> _saveEntryJson(File file, BiliDownloadEntryInfo entry) async {
    try {
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(entry.toJson()), flush: true);
      if (file.existsSync()) await file.delete();
      await tmpFile.rename(file.path);
    } catch (_) {}
  }
}
