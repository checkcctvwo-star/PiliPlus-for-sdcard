import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File, Platform;

import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/universal_cache_recovery_engine.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, debugPrint, VoidCallback;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  static const _maxDanmakuConcurrency = 4;

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value != null) {
      curDownload
        ..value!.status = status
        ..refresh();
    }
  }

  DownloadManager? _downloadManager;
  DownloadManager? _audioDownloadManager;

  late Future<void> waitForInitialization;

  final _isBatchProcessing = false.obs;
  bool get isBatchProcessing => _isBatchProcessing.value;

  Future<void> pauseAllTasks() async {
    if (curDownload.value != null &&
        curDownload.value!.status.isDownloading) {
      curDownload.value!.status = DownloadStatus.pause;
      curDownload.refresh();
    }
    for (final item in waitDownloadQueue) {
      if (item.status == DownloadStatus.wait || item.status.isDownloading) {
        item.status = DownloadStatus.pause;
      }
    }
    waitDownloadQueue.refresh();

    await cancelDownload(isDelete: false, downloadNext: false);
    await DownloadManager.pauseDownload();
  }

  Future<void> resumeAllTasks() async {
    if (_isBatchProcessing.value) return;
    _isBatchProcessing.value = true;
    try {
      for (final item in waitDownloadQueue) {
        if (item.status == DownloadStatus.pause ||
            item.status == DownloadStatus.failDownload) {
          item.status = DownloadStatus.wait;
        }
      }
      waitDownloadQueue.refresh();
      nextDownload();
      await DownloadManager.resumeAll();
    } finally {
      _isBatchProcessing.value = false;
    }
  }

  Future<void> toggleAllTasks() async {
    if (_isBatchProcessing.value) return;

    if (waitDownloadQueue.any((e) =>
        e.status == DownloadStatus.downloading ||
        e.status == DownloadStatus.wait)) {
      _isBatchProcessing.value = true;
      try {
        await pauseAllTasks();
        await DownloadManager.stopAll();
      } finally {
        _isBatchProcessing.value = false;
      }
    } else {
      await resumeAllTasks();
    }
  }

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
  }

  void initDownloadList() {
    waitForInitialization = () async {
      await DownloadManager.init();

      // 1. 优先扫描暂存目录（download_staging）中中断或未提交的任务，恢复至待下载队列
      try {
        final stagingBase = path.join(appSupportDirPath, 'download_staging');
        final stagingEntries =
            await UniversalCacheRecoveryEngine.scanStagingEntries(stagingBase);
        for (final entry in stagingEntries) {
          if (!waitDownloadQueue.any((e) => e.cid == entry.cid)) {
            waitDownloadQueue.add(entry);
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Failed to recover staging entries: $e');
      }

      // 2. 扫描并加载已下载完成的离线缓存列表
      await _readDownloadList();

      // 3. 关联 Aria 原生底层未完成任务进度
      final unfinishedTasks = await DownloadManager.getUnfinishedTasks();
      for (final task in unfinishedTasks) {
        final filePath = task['filePath'] as String?;
        if (filePath == null) continue;

        final match = waitDownloadQueue.firstWhereOrNull((e) {
          final typeTag = e.typeTag;
          if (typeTag == null) return false;
          final videoPath1 =
              path.join(e.entryDirPath, typeTag, PathUtils.videoNameType1);
          final videoPath2 =
              path.join(e.entryDirPath, typeTag, PathUtils.videoNameType2);
          final audioPath =
              path.join(e.entryDirPath, typeTag, PathUtils.audioNameType2);
          return filePath == videoPath1 ||
              filePath == videoPath2 ||
              filePath == audioPath;
        });

        if (match != null) {
          match.status = DownloadStatus.pause;
          match.downloadedBytes =
              (task['currentProgress'] as num?)?.toInt() ?? match.downloadedBytes;
        }
      }
      waitDownloadQueue.refresh();
      flagNotifier.refresh();
    }();
  }

  /// 防 412 串行深度自愈：扫描磁盘恢复未录入的任务时，使用严格串行遍历，并在请求 B 站 API 前强制等待 600ms，彻底绕过 WAF 412 封禁
  Future<void> deepScanRecovery() async {
    final tempWaitQueue = <BiliDownloadEntryInfo>[...waitDownloadQueue];
    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;
    final safUri = GStorage.setting.get('downloadPath') as String?;

    final folders = <String>{};
    final downloadPathStr = await _getDownloadPath();
    final localDir = Directory(downloadPathStr);

    if (localDir.existsSync()) {
      await for (final dir in localDir.list()) {
        if (dir is Directory) {
          folders.add(path.basename(dir.path));
        }
      }
    }

    if (type == 2 && safUri != null && safUri.isNotEmpty && Platform.isAndroid) {
      try {
        final safDirs = await DownloadManager.scanSafDirectory(safUri);
        folders.addAll(safDirs);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('SAF deep scan error: $e');
        }
      }
    }

    for (final avidStr in folders) {
      if (avidStr.startsWith('s_')) continue; // skip bangumi for now
      final avidPath = path.join(downloadPathStr, avidStr);
      final dir = Directory(avidPath);
      if (!dir.existsSync()) continue;

      final cDirs = dir.listSync();
      for (final cDir in cDirs) {
        if (cDir is Directory) {
          final entryFile = File(path.join(cDir.path, _entryFile));
          if (!entryFile.existsSync()) {
            String? typeTag;
            final typeDirs = cDir.listSync();
            for (final typeDir in typeDirs) {
              if (typeDir is Directory) {
                final potentialIndex =
                    File(path.join(typeDir.path, _indexFile));
                if (potentialIndex.existsSync()) {
                  typeTag = path.basename(typeDir.path);
                  break;
                }
              }
            }
            if (typeTag != null) {
              try {
                // 防 412 串行深度自愈：请求 B 站 API 前强制等待 600ms，彻底绕过 WAF 412 封禁
                await Future.delayed(const Duration(milliseconds: 600));
                final res = await Request.dio.get(
                  'https://api.bilibili.com/x/web-interface/view?aid=$avidStr',
                );
                final data = res.data['data'];
                if (data != null) {
                  final title = data['title'] ?? 'Unknown';
                  final pic = data['pic'] ?? '';
                  final owner = data['owner']?['name'] ?? 'Unknown';
                  final bvid = data['bvid'] ?? '';
                  final cidStr =
                      path.basename(cDir.path).replaceFirst('c_', '');
                  final cid = int.tryParse(cidStr) ?? 0;
                  int pageNum = 1;
                  String partName = title;
                  final pages = data['pages'];
                  if (pages is List) {
                    for (final p in pages) {
                      if (p['cid'] == cid) {
                        pageNum = p['page'] ?? 1;
                        partName = p['part'] ?? title;
                        break;
                      }
                    }
                  }

                  final pageData = PageInfo(
                    cid: cid,
                    page: pageNum,
                    hasAlias: false,
                    tid: 0,
                    part: partName,
                    downloadTitle: '视频已缓存完成',
                    downloadSubtitle: title,
                  );

                  final entry = BiliDownloadEntryInfo(
                    mediaType: 2,
                    hasDashAudio: false,
                    isCompleted: false,
                    totalBytes: 0,
                    downloadedBytes: 0,
                    title: title,
                    typeTag: typeTag,
                    cover: pic,
                    preferedVideoQuality: int.tryParse(typeTag) ?? 16,
                    qualityPithyDescription: '',
                    guessedTotalBytes: 0,
                    totalTimeMilli: 0,
                    danmakuCount: 0,
                    timeUpdateStamp:
                        DateTime.now().millisecondsSinceEpoch ~/ 1000,
                    timeCreateStamp:
                        DateTime.now().millisecondsSinceEpoch ~/ 1000,
                    canPlayInAdvance: true,
                    interruptTransformTempFile: false,
                    spid: 0,
                    bvid: bvid,
                    avid: int.tryParse(avidStr) ?? 0,
                    ownerName: owner,
                    pageData: pageData,
                  )
                    ..pageDirPath = dir.path
                    ..entryDirPath = cDir.path;

                  await _updateBiliDownloadEntryJson(entry);
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('API reconstruction error: $e');
                }
              }
            }
          }

          if (entryFile.existsSync()) {
            try {
              final entryJson = await entryFile.readAsString();
              final entry = BiliDownloadEntryInfo.fromJson(
                jsonDecode(entryJson) as Map<String, dynamic>,
              )
                ..pageDirPath = dir.path
                ..entryDirPath = cDir.path;

              final tag = entry.typeTag;
              if (tag != null) {
                final typeDir = Directory(path.join(cDir.path, tag));
                if (typeDir.existsSync()) {
                  final videoFile = File(
                    path.join(typeDir.path, PathUtils.videoNameType2),
                  );
                  final audioFile = File(
                    path.join(typeDir.path, PathUtils.audioNameType2),
                  );
                  final type1File = File(
                    path.join(typeDir.path, PathUtils.videoNameType1),
                  );

                  int actualBytes = 0;
                  if (videoFile.existsSync()) actualBytes += videoFile.lengthSync();
                  if (audioFile.existsSync()) actualBytes += audioFile.lengthSync();
                  if (type1File.existsSync()) actualBytes += type1File.lengthSync();

                  if (entry.totalBytes > 0 && actualBytes < entry.totalBytes) {
                    entry
                      ..isCompleted = false
                      ..status = DownloadStatus.wait;
                    await _updateBiliDownloadEntryJson(entry);
                    tempWaitQueue.add(entry);
                  }
                }
              }
            } catch (e) {
              if (kDebugMode) {
                debugPrint('Integrity check error: $e');
              }
            }
          }
        }
      }
    }
    waitDownloadQueue.assignAll(tempWaitQueue.toSet().toList());

    await _readDownloadList();
    waitDownloadQueue.refresh();
    flagNotifier.refresh();
  }

  Future<void> _readDownloadList() async {
    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;
    final basePath = downloadPath.isNotEmpty ? downloadPath : await _getDownloadPath();
    final recovered = await UniversalCacheRecoveryEngine.scanAndRecoverAll(
      basePath: basePath,
      dirType: type,
    );

    final activeCids = waitDownloadQueue.map((e) => e.cid).toSet();
    if (curDownload.value case final cur?) {
      activeCids.add(cur.cid);
    }

    final completedList = <BiliDownloadEntryInfo>[];
    for (final entry in recovered) {
      if (!activeCids.contains(entry.cid)) {
        if (entry.isCompleted) {
          completedList.add(entry);
        } else {
          waitDownloadQueue.add(entry..status = DownloadStatus.wait);
        }
      }
    }

    downloadList.assignAll(completedList);
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
  }

  void downloadVideo({
    required int index,
    required Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    required VideoQuality videoQuality,
    SeasonInfo? seasonInfo,
  }) {
    final cid = page.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final pageData = PageInfo(
      cid: cid,
      page: page.page!,
      from: page.from,
      part: page.part,
      vid: page.vid,
      hasAlias: false,
      tid: 0,
      width: 0,
      height: 0,
      rotate: 0,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: videoDetail?.title ?? videoArc!.title,
    );
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: videoDetail?.title ?? videoArc!.title!,
      typeTag: videoQuality.code.toString(),
      cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
      preferedVideoQuality: videoQuality.code,
      qualityPithyDescription: videoQuality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: (page.duration ?? 0) * 1000,
      danmakuCount:
          videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: videoDetail?.aid ?? videoArc!.aid!,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: videoDetail?.bvid ?? videoArc!.bvid!,
      ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
      ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
      pageData: pageData,
      seasonInfo: seasonInfo,
    );
    _createDownload(entry);
  }

  void downloadBangumi({
    required int index,
    required PgcInfoModel pgcItem,
    required pgc.EpisodeItem episode,
    required VideoQuality quality,
  }) {
    final cid = episode.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(
      avId: episode.aid!,
      cid: cid,
    );
    final ep = EpInfo(
      avId: source.avId,
      page: index,
      danmaku: source.cid,
      cover: episode.cover!,
      episodeId: episode.id!,
      index: episode.title!,
      indexTitle: episode.longTitle ?? '',
      showTitle: episode.showTitle,
      from: episode.from ?? 'bangumi',
      seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
      width: 0,
      height: 0,
      rotate: 0,
      link: episode.link ?? '',
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      sortIndex: index,
    );
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
      typeTag: quality.code.toString(),
      cover: episode.cover!,
      preferedVideoQuality: quality.code,
      qualityPithyDescription: quality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli:
          (episode.duration ?? 0) *
          (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
      danmakuCount: pgcItem.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      spid: 0,
      seasonId: pgcItem.seasonId!.toString(),
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      avid: source.avId,
      ep: ep,
      source: source,
      ownerId: pgcItem.upInfo?.mid,
      ownerName: pgcItem.upInfo?.uname,
      pageData: null,
    );
    _createDownload(entry);
  }

  Future<void> _createDownload(BiliDownloadEntryInfo entry) async {
    final entryDir = await _getDownloadEntryDir(entry);
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
    await _updateBiliDownloadEntryJson(entry);
    waitDownloadQueue.add(entry);
    if (curDownload.value?.status.isDownloading != true) {
      startDownload(entry);
    }
  }

  Future<Directory> _getDownloadEntryDir(BiliDownloadEntryInfo entry) async {
    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }

    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;

    if (type == 2 || downloadPath.startsWith('content://')) {
      final stagingBase = path.join(appSupportDirPath, 'download_staging');
      final pageDir = Directory(path.join(stagingBase, dirName, pageDirName));
      if (!pageDir.existsSync()) {
        await pageDir.create(recursive: true);
      }
      return pageDir;
    }

    final pageDir = Directory(
      path.join(await _getDownloadPath(), dirName, pageDirName),
    );
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;
    if (type == 2 || downloadPath.startsWith('content://')) {
      return downloadPath;
    }
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    return _lock.synchronized(() async {
      await _downloadManager?.cancel(isDelete: false);
      await _audioDownloadManager?.cancel(isDelete: false);
      _downloadManager = null;
      _audioDownloadManager = null;
      if (curDownload.value case final curEntry?) {
        if (curEntry.status.isDownloading) {
          curEntry.status = DownloadStatus.pause;
        }
      }

      _curCid = entry.cid;
      curDownload.value = entry;
      waitDownloadQueue.refresh();
      await _startDownload(entry);
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) return false;
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      try {
        if (!isUpdate) {
          _updateCurStatus(DownloadStatus.getDanmaku);
        }
        final seg = (entry.totalTimeMilli / DmUtils.segLength).ceil();
        if (seg <= 0) {
          throw StateError('Invalid danmaku segment count: $seg');
        }

        final danmaku = (await DmGrpc.dmSegMobile(
          cid: cid,
          segmentIndex: 1,
        )).data;
        for (var start = 2; start <= seg; start += _maxDanmakuConcurrency) {
          final end = start + _maxDanmakuConcurrency - 1;
          final responses = await Future.wait([
            for (var index = start; index <= seg && index <= end; index++)
              DmGrpc.dmSegMobile(cid: cid, segmentIndex: index),
          ]);
          for (final response in responses) {
            danmaku.elems.addAll(response.data.elems);
          }
          responses.clear();
        }
        await danmakuFile.writeAsBytes(danmaku.writeToBuffer());

        return true;
      } catch (e) {
        if (!isUpdate) {
          _updateCurStatus(DownloadStatus.failDanmaku);
        }
        if (kDebugMode) SmartDialog.showToast(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<bool> _downloadCover({
    required BiliDownloadEntryInfo entry,
  }) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      final file = (await CacheManager.manager.getFileFromCache(
        entry.cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(entry.cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> updateSegments(BiliDownloadEntryInfo entry) {
    if (entry.pageData != null) {
      return _updateBlockSegments(entry);
    } else {
      return _updatePgcSegments(entry);
    }
  }

  Future<bool> _updateBlockSegments(BiliDownloadEntryInfo entry) async {
    final res = await SponsorBlock.getSkipSegments(
      bvid: entry.bvid,
      cid: entry.pageData!.cid,
    );
    if (res case Success(:final response)) {
      if (response.isNotEmpty) {
        entry.segments = response;
        await _updateBiliDownloadEntryJson(entry);
      }
      return true;
    }
    return false;
  }

  Future<bool> _updatePgcSegments(BiliDownloadEntryInfo entry) async {
    final ep = entry.ep;
    if (ep == null) return false;
    final res = await VideoHttp.videoUrl(
      avid: entry.avid,
      bvid: entry.bvid,
      cid: entry.cid,
      seasonId: entry.seasonId,
      epid: ep.episodeId,
      qn: entry.preferedVideoQuality,
      tryLook: false,
      videoType: switch (ep.from) {
        'pugv' => .pugv,
        _ => .pgc,
      },
    );
    if (res case Success(:final response)) {
      final clipInfoList = response.clipInfoList;
      if (clipInfoList != null && clipInfoList.isNotEmpty) {
        entry.segments = clipInfoList;
        await _updateBiliDownloadEntryJson(entry);
      }
      return true;
    }
    return false;
  }

  Future<void> _startDownload(BiliDownloadEntryInfo entry) async {
    try {
      if (!await downloadDanmaku(entry: entry)) {
        return;
      }

      // ugc segments
      if (entry.pageData != null && Pref.enableSponsorBlock) {
        await _updateBlockSegments(entry);
      }

      _updateCurStatus(DownloadStatus.getPlayUrl);

      final noSegmentBefore = entry.segments == null;

      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );

      // pgc segments
      if (noSegmentBefore && entry.segments != null) {
        await _updateBiliDownloadEntryJson(entry);
      }

      final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
      if (!videoDir.existsSync()) {
        await videoDir.create(recursive: true);
      }

      final mediaJsonFile = File(path.join(videoDir.path, _indexFile));
      await Future.wait([
        mediaJsonFile.writeAsString(jsonEncode(mediaFileInfo.toJson())),
        _downloadCover(entry: entry),
      ]);

      if (curDownload.value?.cid != entry.cid) {
        return;
      }

      switch (mediaFileInfo) {
        case Type1 mediaFileInfo:
          final first = mediaFileInfo.segmentList.first;
          _downloadManager = DownloadManager(
            url: first.url,
            path: path.join(videoDir.path, PathUtils.videoNameType1),
            onReceiveProgress: _onReceive,
            onDone: _onDone,
          );
          break;
        case Type2 mediaFileInfo:
          _downloadManager = DownloadManager(
            url: mediaFileInfo.video.first.baseUrl,
            path: path.join(videoDir.path, PathUtils.videoNameType2),
            onReceiveProgress: _onReceive,
            onDone: _onDone,
          );
          final audio = mediaFileInfo.audio;
          if (audio != null && audio.isNotEmpty) {
            _audioDownloadManager = DownloadManager(
              url: audio.first.baseUrl,
              path: path.join(videoDir.path, PathUtils.audioNameType2),
              onReceiveProgress: null,
              onDone: _onAudioDone,
            );
          }
          late final first = mediaFileInfo.video.first;
          entry.pageData
            ?..width = first.width
            ..height = first.height;
          entry.ep
            ?..width = first.width
            ..height = first.height;
          _updateBiliDownloadEntryJson(entry);
          break;
        default:
          break;
      }
    } catch (e) {
      _updateCurStatus(DownloadStatus.failPlayUrl);
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
  }

  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) async {
    if (entry.entryDirPath.startsWith('content://')) {
      return;
    }
    try {
      final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
      final tmpFile = File('${entryJsonFile.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(entry.toJson()), flush: true);
      try {
        await tmpFile.rename(entryJsonFile.path);
      } catch (_) {
        if (entryJsonFile.existsSync()) {
          await entryJsonFile.delete();
        }
        await tmpFile.rename(entryJsonFile.path);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_updateBiliDownloadEntryJson error: $e');
    }
  }

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      if (progress == 0 && total != 0) {
        _updateBiliDownloadEntryJson(entry..totalBytes = total);
      }
      entry
        ..downloadedBytes = progress
        ..status = DownloadStatus.downloading;
      curDownload.refresh();
    }
  }

  void _onDone([Object? error]) {
    if (error != null) {
      _updateCurStatus(_downloadManager?.status ?? DownloadStatus.pause);
      return;
    }

    final status = switch (_audioDownloadManager?.status) {
      DownloadStatus.downloading => DownloadStatus.audioDownloading,
      DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
      _ => _downloadManager?.status ?? DownloadStatus.pause,
    };
    _updateCurStatus(status);

    if (curDownload.value case final curEntryInfo?) {
      curEntryInfo.downloadedBytes = curEntryInfo.totalBytes;
      if (status == DownloadStatus.completed) {
        _completeDownload();
      } else {
        _updateBiliDownloadEntryJson(curEntryInfo);
      }
    }
  }

  void _onAudioDone([Object? error]) {
    if (_downloadManager?.status == DownloadStatus.completed) {
      if (error == null) {
        _completeDownload();
      } else {
        final status = _audioDownloadManager?.status ?? DownloadStatus.pause;
        _updateCurStatus(
          status == DownloadStatus.failDownload
              ? DownloadStatus.failDownloadAudio
              : status,
        );
      }
    }
  }

  Future<void> _completeDownload() async {
    final entry = curDownload.value;
    if (entry == null) {
      return;
    }

    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }

    // 混流管道接入：当视频与音频下载完成时，调用 DownloadManager.mergeDashMedia 将 video.m4s 与 audio.m4s 混流为标准 0.mp4
    final typeTag = entry.typeTag;
    if (typeTag != null) {
      final videoDir = Directory(path.join(entry.entryDirPath, typeTag));
      final videoPath = path.join(videoDir.path, PathUtils.videoNameType2);
      final audioPath = path.join(videoDir.path, PathUtils.audioNameType2);
      final outputPath = path.join(videoDir.path, PathUtils.videoNameType1);

      if (File(videoPath).existsSync() && File(audioPath).existsSync()) {
        try {
          final success = await DownloadManager.mergeDashMedia(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
          );
          if (success && File(outputPath).existsSync()) {
            final outputFile = File(outputPath);
            final length = await outputFile.length();
            entry
              ..mediaType = 1
              ..totalBytes = length
              ..downloadedBytes = length;
            await File(videoPath).tryDel();
            await File(audioPath).tryDel();
          } else {
            // 混流失败时，确保保持 mediaType=2 并启用 hasDashAudio，绝不破坏双轨播放机制
            entry
              ..mediaType = 2
              ..hasDashAudio = true;
          }
        } catch (e) {
          entry
            ..mediaType = 2
            ..hasDashAudio = true;
          if (kDebugMode) {
            debugPrint('mergeDashMedia error: $e');
          }
        }
      } else if (File(outputPath).existsSync()) {
        final length = await File(outputPath).length();
        entry
          ..mediaType = 1
          ..totalBytes = length
          ..downloadedBytes = length;
      } else {
        entry
          ..mediaType = 2
          ..hasDashAudio = File(audioPath).existsSync();
      }
    }

    entry
      ..downloadedBytes = entry.totalBytes
      ..isCompleted = true;
    await _updateBiliDownloadEntryJson(entry);

    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;

    // 如果目标是 SAF 树形目录模式，将暂存目录原子提交到 SAF DocumentFile 树
    if (type == 2 || downloadPath.startsWith('content://')) {
      final stagingEntryPath = entry.entryDirPath;
      final commitRes = await DownloadManager.commitStagingEntry(
        stagingEntryPath: stagingEntryPath,
        targetType: 2,
        targetBaseDir: downloadPath,
        relativePath: '$dirName/$pageDirName',
      );
      if (commitRes != null && commitRes['success'] == true) {
        final safUris = (commitRes['safFileUris'] as Map?)?.cast<String, String>();
        if (safUris != null && safUris.isNotEmpty) {
          entry.safFileUris = safUris;
        }
        final resolvedTargetBase = await DownloadManager.resolveContentUri(downloadPath);
        if (resolvedTargetBase != null && resolvedTargetBase.isNotEmpty) {
          entry
            ..pageDirPath = path.join(resolvedTargetBase, dirName)
            ..entryDirPath = path.join(resolvedTargetBase, dirName, pageDirName);
          await _updateBiliDownloadEntryJson(entry);
        } else {
          entry
            ..pageDirPath = downloadPath
            ..entryDirPath = '$downloadPath/$dirName/$pageDirName';
        }
      }
    }

    waitDownloadQueue.remove(entry);
    downloadList.removeWhere((e) => e.avid == entry.avid && e.cid == entry.cid);
    downloadList.insert(0, entry);
    flagNotifier.refresh();
    _curCid = null;
    curDownload.value = null;
    _downloadManager = null;
    _audioDownloadManager = null;
    nextDownload();
  }

  void nextDownload() {
    if (waitDownloadQueue.isNotEmpty) {
      startDownload(waitDownloadQueue.first);
    }
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) async {
    if (removeList) {
      downloadList.remove(entry);
    }
    if (removeQueue) {
      waitDownloadQueue.remove(entry);
    }
    if (curDownload.value?.cid == entry.cid) {
      await cancelDownload(
        isDelete: true,
        downloadNext: downloadNext,
      );
    }
    final downloadDir = Directory(entry.pageDirPath);
    if (downloadDir.existsSync()) {
      if (!await downloadDir.lengthGte(2)) {
        await downloadDir.tryDel(recursive: true);
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
        }
      }
    }
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    await Directory(pageDirPath).tryDel(recursive: true);
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> cancelDownload({
    required bool isDelete,
    bool downloadNext = true,
  }) async {
    await _downloadManager?.cancel(isDelete: isDelete);
    await _audioDownloadManager?.cancel(isDelete: isDelete);
    _downloadManager = null;
    _audioDownloadManager = null;
    if (!isDelete) {
      final entry = curDownload.value;
      if (entry != null) {
        await _updateBiliDownloadEntryJson(entry);
      }
    }
    if (isDelete) {
      _curCid = null;
      curDownload.value = null;
    } else {
      _updateCurStatus(DownloadStatus.pause);
    }
    if (downloadNext) {
      nextDownload();
    }
  }
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
