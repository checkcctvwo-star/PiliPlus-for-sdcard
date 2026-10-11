import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/utils/path_utils.dart';
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

            if (jsonStr != null && jsonStr.isNotEmpty) {
              final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
              final entry = BiliDownloadEntryInfo.fromLenientJson(jsonMap)
                ..pageDirPath = pageDirUri
                ..entryDirPath = entryDirUri
                ..isCompleted = true
                ..status = DownloadStatus.completed;

              entry.safFileUris ??= {};
              if (entryFileUri != null) {
                entry.safFileUris![_entryFileName] = entryFileUri;
              }
              recovered.add(entry);
            } else {
              // 离线逆向合成 Tier 2 (仅有媒体文件无 entry.json)
              final avid = int.tryParse(pageDirName.replaceAll(RegExp(r'\D'), '')) ?? 0;
              final cid = int.tryParse(entryDirName.replaceAll(RegExp(r'\D'), '')) ?? 0;
              final synthetic = BiliDownloadEntryInfo(
                mediaType: 1,
                hasDashAudio: false,
                isCompleted: true,
                totalBytes: 0,
                downloadedBytes: 0,
                title: pageDirName.isNotEmpty ? pageDirName : '离线缓存 $avid',
                cover: '',
                preferedVideoQuality: 80,
                qualityPithyDescription: '高清',
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
              )
                ..pageDirPath = pageDirUri
                ..entryDirPath = entryDirUri
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
        if (!rootDir.existsSync()) {
          return recovered;
        }

        final pageEntities = rootDir.listSync();
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

                // 检查 0.mp4 是否已存在
                final rootMp4 = File(p.join(entryDir.path, _mp4FileName));
                final tag = entry.typeTag;
                final tagMp4 = tag != null
                    ? File(p.join(entryDir.path, tag, _mp4FileName))
                    : null;

                if (rootMp4.existsSync()) {
                  entry
                    ..isCompleted = true
                    ..mediaType = 1
                    ..totalBytes = rootMp4.lengthSync()
                    ..downloadedBytes = rootMp4.lengthSync()
                    ..status = DownloadStatus.completed;
                } else if (tagMp4 != null && tagMp4.existsSync()) {
                  entry
                    ..isCompleted = true
                    ..mediaType = 1
                    ..totalBytes = tagMp4.lengthSync()
                    ..downloadedBytes = tagMp4.lengthSync()
                    ..status = DownloadStatus.completed;
                } else {
                  // 尝试检测遗留的未混流 .m4s 切片并自愈转码
                  if (tag != null) {
                    final videoM4s = File(p.join(entryDir.path, tag, _videoM4sFileName));
                    final audioM4s = File(p.join(entryDir.path, tag, _audioM4sFileName));
                    if (videoM4s.existsSync() && audioM4s.existsSync()) {
                      final targetMp4 = p.join(entryDir.path, tag, _mp4FileName);
                      final muxSuccess = await DownloadManager.mergeDashMedia(
                        videoPath: videoM4s.path,
                        audioPath: audioM4s.path,
                        outputPath: targetMp4,
                      );
                      if (muxSuccess && File(targetMp4).existsSync()) {
                        final len = File(targetMp4).lengthSync();
                        entry
                          ..isCompleted = true
                          ..mediaType = 1
                          ..totalBytes = len
                          ..downloadedBytes = len
                          ..status = DownloadStatus.completed;
                        // 更新持久化 entry.json
                        await _saveEntryJson(entryFile, entry);
                      }
                    }
                  }
                }

                recovered.add(entry);
              } catch (e) {
                if (kDebugMode) debugPrint('POSIX entry.json parse error: $e');
              }
            } else {
              // 无 entry.json 但存在媒体文件：离线逆向合成
              File? foundMp4;
              final directMp4 = File(p.join(entryDir.path, _mp4FileName));
              if (directMp4.existsSync()) {
                foundMp4 = directMp4;
              } else {
                for (final sub in entryDir.listSync()) {
                  if (sub is Directory) {
                    final subMp4 = File(p.join(sub.path, _mp4FileName));
                    if (subMp4.existsSync()) {
                      foundMp4 = subMp4;
                      break;
                    }
                  }
                }
              }

              if (foundMp4 != null) {
                final pageName = p.basename(pageDir.path);
                final entryName = p.basename(entryDir.path);
                final avid = int.tryParse(pageName.replaceAll(RegExp(r'\D'), '')) ?? 0;
                final cid = int.tryParse(entryName.replaceAll(RegExp(r'\D'), '')) ?? 0;
                final fileLen = foundMp4.lengthSync();

                final synthetic = BiliDownloadEntryInfo(
                  mediaType: 1,
                  hasDashAudio: false,
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

                // 补全持久化 entry.json 保证下次启动秒开
                await _saveEntryJson(entryFile, synthetic);
                recovered.add(synthetic);
              }
            }
          }
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

    final result = uniqueMap.values.toList();
    result.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
    return result;
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
