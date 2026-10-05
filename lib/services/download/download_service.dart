import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File, Platform;

import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:collection/collection.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/scan_plan.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
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

  /// The outcome of the most recent [deepScanRecovery] pass.
  ///
  /// Kept so a caller that did not await the pass — the automatic scan on page
  /// open, for one — can still read what happened.
  DeepScanReport lastDeepScanReport = DeepScanReport.empty;

  /// How long a native SAF directory listing stays usable before it is
  /// re-fetched.
  ///
  /// Deliberately shorter than a "recently picked directory" window: a user who
  /// just pointed the app at a new folder and tapped scan must see that folder,
  /// not a listing from before they chose it. Past this age the tree is walked
  /// again, because a download that finished in the meantime is exactly what
  /// the scan is looking for.
  static const _safScanCacheTtl = Duration(minutes: 10);

  ({String uri, List<String> dirs, int scannedAt})? _safScanCache;

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value != null) {
      curDownload.value!.status = status;
      if (!_isBatchProcessing.value) {
        curDownload.refresh();
      }
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
    for (var item in waitDownloadQueue) {
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
      for (var item in waitDownloadQueue) {
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
        pauseAllTasks();
        await DownloadManager.stopAll();
      } finally {
        _isBatchProcessing.value = false;
      }
    } else {
      await resumeAllTasks();
    }
  }


  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
    
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      if (results.isEmpty) return;
      final result = results.first; // handle single result or first of list
      if (result == ConnectivityResult.wifi || result == ConnectivityResult.ethernet) {
        if (GStorage.setting.get(SettingBoxKey.autoResumeDownloads, defaultValue: true)) {
          resumeAllTasks();
        }
      } else if (result == ConnectivityResult.mobile) {
        if (GStorage.setting.get(SettingBoxKey.autoResumeDownloads, defaultValue: true)) {
          if (Pref.allowCellularDownload) {
            resumeAllTasks();
          } else {
            pauseAllTasks();
          }
        }
      }
    });
  }

  @override
  void onClose() {
    _connectivitySubscription.cancel();
    super.onClose();
  }

  void initDownloadList() {
    waitForInitialization = () async {
      await DownloadManager.init();
      await _readDownloadList();
      final unfinishedTasks = await DownloadManager.getUnfinishedTasks();
      for (final task in unfinishedTasks) {
        final filePath = task['filePath'] as String?;
        if (filePath == null) continue;
        
        final match = downloadList.firstWhereOrNull((e) {
          if (e.safFileUris != null) return false;
          final typeTag = e.typeTag;
          if (typeTag == null) return false;
          final videoPath1 = path.join(e.entryDirPath, typeTag, PathUtils.videoNameType1);
          final videoPath2 = path.join(e.entryDirPath, typeTag, PathUtils.videoNameType2);
          final audioPath = path.join(e.entryDirPath, typeTag, PathUtils.audioNameType2);
          return filePath == videoPath1 || filePath == videoPath2 || filePath == audioPath;
        });
        
        if (match != null && !waitDownloadQueue.contains(match)) {
          match.status = DownloadStatus.pause;
          match.downloadedBytes = (task['currentProgress'] as num?)?.toInt() ?? match.downloadedBytes;
          waitDownloadQueue.add(match);
        }
      }
    }();
  }

  /// Rebuilds entries whose `entry.json` was lost, by walking the download
  /// directory.
  ///
  /// [includeSaf] gates the SAF half of the scan. It is off by default because
  /// this runs on every visit to the download page and a recursive SAF tree walk
  /// is binder-bound; only the explicit "深度恢复" tap pays that cost.
  Future<void> deepScanRecovery({bool includeSaf = false}) async {
    final tempWaitQueue = <BiliDownloadEntryInfo>[...waitDownloadQueue];
    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;
    final safUri = Pref.downloadSafUri;
    final hasSaf = type == 2 && Platform.isAndroid && (safUri?.isNotEmpty ?? false);

    final downloadPathStr = await _getDownloadPath();
    final localDir = Directory(downloadPathStr);

    // Local and SAF names are collected into two separate lists. They used to
    // share one `Set<String>`, which made a bare SAF name indistinguishable from
    // a local directory name — and joining a SAF name onto the local path always
    // produced a path that had never existed, so `existsSync()` discarded every
    // SAF directory without a trace.
    final localDirNames = <String>[];
    if (localDir.existsSync()) {
      await for (final dir in localDir.list()) {
        if (dir is Directory) {
          localDirNames.add(path.basename(dir.path));
        }
      }
    }

    var safDirNames = const <String>[];
    var safScannedAt = 0;
    Object? safError;
    if (hasSaf && includeSaf) {
      final uri = safUri!;
      final cached = _safScanCache;
      final age = cached == null
          ? null
          : DateTime.now().millisecondsSinceEpoch - cached.scannedAt;
      final isFresh = cached != null &&
          cached.uri == uri &&
          age! >= 0 &&
          age <= _safScanCacheTtl.inMilliseconds;

      if (isFresh) {
        safDirNames = cached.dirs;
        safScannedAt = cached.scannedAt;
      } else {
        try {
          // Errors are deliberately not swallowed: a failed SAF scan must be
          // reported, not indistinguishable from a scan that found nothing.
          final scan = await const MethodChannel('com.piliplus/download')
              .invokeMapMethod<String, dynamic>('scanSafDirectory', {'uri': uri});
          safDirNames =
              (scan?['dirs'] as List?)?.cast<String>().toList(growable: false) ??
                  const [];
          safScannedAt = scan?['scannedAt'] as int? ?? 0;
          _safScanCache = (uri: uri, dirs: safDirNames, scannedAt: safScannedAt);
        } catch (e) {
          safError = e;
          // A failed refresh must not leave the previous snapshot readable as
          // if it were current.
          _safScanCache = null;
        }
      }
    }

    final plan = buildScanPlan(
      localDirNames: localDirNames,
      safDirNames: safDirNames,
      safTreeUri: hasSaf ? safUri : null,
    );

    // Names the native scanner reported that no tree URI can address. They
    // cannot be visited, so they are counted rather than folded into the local
    // set to be swallowed by an existence check.
    final unreachableSafNames = unaddressableSafNames(
      safDirNames: safDirNames,
      safTreeUri: hasSaf ? safUri : null,
    );

    var recovered = 0;
    var requeued = 0;
    for (final root in plan.avidRoots) {
      if (root.isSaf) continue;
      // `localPathFor` returns null for SAF roots by construction, so the join
      // below is only ever reached with a name that came from the local disk.
      final avidPath = plan.localPathFor(root, downloadPathStr);
      if (avidPath == null) continue;
      recovered += await _recoverLocalRoot(avidPath, root.name, tempWaitQueue);
    }

    var safVerified = 0;
    final safOrphans = <String>[];
    if (includeSaf && safError == null) {
      // Every SAF root, bangumi included: verification asks whether files this
      // device promised to keep are still there, which is a question about the
      // tree and does not depend on which recovery path the root would use if
      // the files turned out to be missing.
      for (final root in plan.safRoots) {
        final result = await _verifySafRoot(root, tempWaitQueue, safOrphans);
        safVerified += result.verified;
        requeued += result.requeued;
      }
    }

    // Bangumi seasons reach a dedicated pass instead of being skipped. A season
    // directory is `s_<seasonId>`, not an avid, so feeding it to the avid
    // `view?aid=` lookup returns an unrelated video or nothing at all. The
    // prefix is parsed here so the dedicated pass receives a real season id.
    //
    // Only local roots: a SAF season has no `entry.json` (only media artifacts
    // are copied there), so there is nothing on disk to check. Its files were
    // already accounted for by `_verifySafRoot` above.
    var bangumiChecked = 0;
    final unrecoveredBangumi = <String>[];
    for (final root in plan.bangumiRoots) {
      if (root.isSaf) continue;
      final name = root.name;
      final seasonId =
          name.startsWith('s_') ? int.tryParse(name.substring(2)) : null;
      final checked = await _checkBangumiRoot(
        seasonDir: Directory(path.join(downloadPathStr, name)),
        seasonId: seasonId,
        tempWaitQueue: tempWaitQueue,
      );
      bangumiChecked += checked;
      if (checked == 0) unrecoveredBangumi.add(name);
    }

    waitDownloadQueue.assignAll(tempWaitQueue.toSet().toList());

    await _readDownloadList();
    waitDownloadQueue.refresh();

    final report = DeepScanReport(
      recovered: recovered,
      requeued: requeued,
      safVerified: safVerified,
      safOrphans: safOrphans,
      unrecoveredBangumi: unrecoveredBangumi,
      unreachableSafNames: unreachableSafNames,
      bangumiChecked: bangumiChecked,
      safScanned: hasSaf && includeSaf && safError == null,
      safScannedAt: safScannedAt,
      safError: safError,
    );
    lastDeepScanReport = report;
    flagNotifier.refresh();
  }

  /// Rebuilds or requeues every entry under one local avid directory.
  ///
  /// Returns how many entries were rebuilt from the B站 API.
  Future<int> _recoverLocalRoot(
    String avidPath,
    String avidName,
    List<BiliDownloadEntryInfo> tempWaitQueue,
  ) async {
    final dir = Directory(avidPath);
    var recovered = 0;

    await for (final cDir in dir.list()) {
      if (cDir is Directory) {
        final entryFile = File(path.join(cDir.path, _entryFile));
        if (!entryFile.existsSync()) {
          String? typeTag;
          await for (final typeDir in cDir.list()) {
            if (typeDir is Directory) {
              final potentialIndex = File(path.join(typeDir.path, _indexFile));
              if (potentialIndex.existsSync()) {
                typeTag = path.basename(typeDir.path);
                break;
              }
            }
          }
          if (typeTag != null) {
            try {
              final res = await Request.dio.get('https://api.bilibili.com/x/web-interface/view?aid=$avidName');
              final data = res.data['data'];
              if (data != null) {
                final title = data['title'] ?? 'Unknown';
                final pic = data['pic'] ?? '';
                final owner = data['owner']?['name'] ?? 'Unknown';
                final bvid = data['bvid'] ?? '';
                final cidStr = path.basename(cDir.path).replaceFirst('c_', '');
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
                  timeUpdateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                  timeCreateStamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                  canPlayInAdvance: true,
                  interruptTransformTempFile: false,
                  spid: 0,
                  bvid: bvid,
                  avid: int.tryParse(avidName) ?? 0,
                  ownerName: owner,
                  pageData: pageData,
                )
                  ..pageDirPath = dir.path
                  ..entryDirPath = cDir.path;

                await _updateBiliDownloadEntryJson(entry);
                recovered++;
              }
            } catch (e) {
              debugPrint('API reconstruction error: $e');
            }
          }
        }

        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = dir.path
              ..entryDirPath = cDir.path;

            final tag = entry.typeTag;
            if (tag != null) {
              final typeDir = Directory(path.join(cDir.path, tag));
              if (typeDir.existsSync()) {
                final actualBytes = await _measureLocalArtifacts(typeDir);
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
            debugPrint('Integrity check error: $e');
          }
        }
      }
    }
    return recovered;
  }

  /// Verifies the SAF copies of already-migrated entries under [root].
  ///
  /// The SAF tree holds media artifacts only — `_migrateToSafIfNeeded` copies
  /// `0.mp4` or `video.m4s`+`audio.m4s` and never `entry.json`. So this cannot
  /// rebuild a task; it can only answer "are the files this device promised to
  /// keep still there". Anything in the tree that no local entry claims is
  /// reported as an orphan rather than deleted: a previous install may have
  /// copied it, and the tree holds no metadata to tell wanted from stray.
  ///
  /// Only *missing* files trigger a requeue. Comparing sizes instead would be
  /// theatre: `totalBytes` is populated from the video stream's `total` only, so
  /// any comparison against video+audio on disk is satisfied by construction and
  /// would report every intact download as broken.
  Future<({int verified, int requeued})> _verifySafRoot(
    ScanRoot root,
    List<BiliDownloadEntryInfo> tempWaitQueue,
    List<String> orphans,
  ) async {
    final treeUri = root.uri;
    if (treeUri == null || treeUri.isEmpty) {
      orphans.add(root.name);
      return (verified: 0, requeued: 0);
    }

    final files = await DownloadManager.scanSafFiles(
      treeUri: treeUri,
      relativePath: root.name,
    );

    // Group the tree contents by their first path segment: `c_<cid>` for UGC,
    // `<episodeId>` for bangumi. That segment is the only identity the tree
    // carries — there is no `entry.json` in here to say what a file is for.
    final groups = <String, List<String>>{};
    for (final rel in files.keys) {
      final idx = rel.indexOf('/');
      if (idx <= 0) {
        orphans.add(rel);
        continue;
      }
      groups.putIfAbsent(rel.substring(0, idx), () => []).add(rel);
    }

    var verified = 0;
    var requeued = 0;
    final claimed = <String>{};

    // Walk the entries this device says it migrated. A group with no files
    // means the copy is gone — that is the loss this whole pass exists to
    // catch, and it is only visible by looking at the local entries, since a
    // missing group leaves no trace in the tree.
    for (final entry in _entriesForSafRoot(root.name)) {
      if (entry.safFileUris == null) continue;
      final group = _safGroupKeyFor(entry);
      if (group == null) continue;
      claimed.add(group);

      if (groups.containsKey(group)) {
        verified++;
        continue;
      }
      entry
        ..isCompleted = false
        ..status = DownloadStatus.wait
        // The recorded URIs no longer resolve; clearing them lets the redownload
        // write a fresh copy instead of failing against a dead handle.
        ..safFileUris = null;
      await _updateBiliDownloadEntryJson(entry);
      tempWaitQueue.add(entry);
      requeued++;
    }

    // Whatever the tree holds that no entry claimed. Reported, never deleted.
    for (final group in groups.entries) {
      if (!claimed.contains(group.key)) orphans.addAll(group.value);
    }

    return (verified: verified, requeued: requeued);
  }

  /// The SAF subdirectory name an entry's artifacts live under.
  ///
  /// `c_<cid>` for a UGC page, `<episodeId>` for a bangumi episode — the two
  /// layouts `_getDownloadEntryDir` writes.
  ///
  /// The `ep`-before-`pageData` order mirrors `_getDownloadEntryDir` exactly.
  /// The two must agree: if they picked different segments for an entry that
  /// somehow has both, the scan would look under a directory the copy was never
  /// written to and report a perfectly intact download as lost.
  String? _safGroupKeyFor(BiliDownloadEntryInfo entry) {
    if (entry.ep case final ep?) return ep.episodeId.toString();
    if (entry.pageData case final page?) return 'c_${page.cid}';
    return null;
  }

  /// Every entry that could own files under the SAF root named [rootName].
  ///
  /// The name is matched against both the avid and the season id because a
  /// SAF root is `s_<seasonId>` for bangumi and `<avid>` for UGC, while
  /// `pageId` normalises the two to season id and avid respectively.
  Iterable<BiliDownloadEntryInfo> _entriesForSafRoot(String rootName) sync* {
    final avid = rootName.startsWith('s_') ? null : rootName;
    final seasonId = rootName.startsWith('s_') ? rootName.substring(2) : null;
    final seen = <BiliDownloadEntryInfo>{};
    for (final entry in <BiliDownloadEntryInfo>[
      ...downloadList,
      ...waitDownloadQueue,
    ]) {
      final matches = (avid != null &&
              (entry.avid.toString() == avid || entry.pageId == avid)) ||
          (seasonId != null && entry.pageId == seasonId);
      if (!matches) continue;
      if (seen.add(entry)) yield entry;
    }
  }

  /// Runs the integrity check a bangumi season directory can support.
  ///
  /// Rebuilding a season from scratch needs the PGC season API, which this pass
  /// does not call. But an `entry.json` that survived carries everything needed
  /// to check whether the files are still all there, so a season that lost its
  /// media can still be pushed back onto the wait queue instead of being
  /// silently forgotten.
  ///
  /// Returns the number of entries checked; zero tells the caller the season
  /// needs a recovery path this pass does not have.
  Future<int> _checkBangumiRoot({
    required Directory seasonDir,
    required int? seasonId,
    required List<BiliDownloadEntryInfo> tempWaitQueue,
  }) async {
    if (seasonId == null || !seasonDir.existsSync()) return 0;

    var checked = 0;
    await for (final entryDir in seasonDir.list()) {
      if (entryDir is! Directory) continue;
      final entryFile = File(path.join(entryDir.path, _entryFile));
      if (!entryFile.existsSync()) continue;
      try {
        final entry = BiliDownloadEntryInfo.fromJson(
          jsonDecode(await entryFile.readAsString()),
        )
          ..pageDirPath = seasonDir.path
          ..entryDirPath = entryDir.path;

        final tag = entry.typeTag;
        if (tag == null || !entry.isCompleted) continue;

        final typeDir = Directory(path.join(entryDir.path, tag));
        if (!typeDir.existsSync()) continue;

        checked++;
        final actualBytes = await _measureLocalArtifacts(typeDir);
        if (entry.totalBytes > 0 && actualBytes < entry.totalBytes) {
          entry
            ..isCompleted = false
            ..status = DownloadStatus.wait
            ..safFileUris = null;
          await _updateBiliDownloadEntryJson(entry);
          tempWaitQueue.add(entry);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Bangumi integrity check error: $e');
      }
    }
    return checked;
  }

  /// Total size of the media artifacts in one type directory.
  Future<int> _measureLocalArtifacts(Directory typeDir) async {
    var bytes = 0;
    for (final name in const [
      PathUtils.videoNameType2,
      PathUtils.audioNameType2,
      PathUtils.videoNameType1,
    ]) {
      final file = File(path.join(typeDir.path, name));
      if (file.existsSync()) bytes += file.lengthSync();
    }
    return bytes;
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    final tempWaitQueue = <BiliDownloadEntryInfo>[...waitDownloadQueue];
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir, tempWaitQueue));
      }
    }
    waitDownloadQueue.assignAll(tempWaitQueue.toSet().toList());
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
    List<BiliDownloadEntryInfo> tempWaitQueue,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    await for (final entryDir in pageDir.list()) {
      if (entryDir is Directory) {
        final entryFile = File(path.join(entryDir.path, _entryFile));
        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path;
            if (entry.isCompleted) {
              bool isLocalAndIncomplete = false;
              if (entry.safFileUris == null && entry.totalBytes > 0 && entry.typeTag != null) {
                final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
                if (videoDir.existsSync()) {
                  final videoFile = File(path.join(videoDir.path, PathUtils.videoNameType2));
                  final type1File = File(path.join(videoDir.path, PathUtils.videoNameType1));
                  File? targetFile;
                  if (videoFile.existsSync()) {
                    targetFile = videoFile;
                  } else if (type1File.existsSync()) {
                    targetFile = type1File;
                  }
                  if (targetFile != null && targetFile.lengthSync() < entry.totalBytes) {
                    isLocalAndIncomplete = true;
                  }
                }
              }
              if (isLocalAndIncomplete) {
                entry.isCompleted = true; // Keep in UI list so user can manage it
                entry.status = DownloadStatus.corrupted;
                result.add(entry);
              } else {
                entry.status = DownloadStatus.completed;
                result.add(entry);
                if (entry.safFileUris == null) {
                  Future.microtask(() async {
                    await _migrateToSafIfNeeded(entry);
                    if (entry.safFileUris != null) {
                      await _updateBiliDownloadEntryJson(entry);
                    }
                  });
                }
              }
            } else {
              tempWaitQueue.add(entry..status = DownloadStatus.wait);
            }
          } catch (e, st) { print("Error reading entry: $e\n$st"); }
        }
      }
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
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
    );
    _createDownload(entry);
  }

  void downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
  ) {
    final cid = episode.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(avId: episode.aid!, cid: cid);
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
    final entryJsonFile = File(path.join(entryDir.path, _entryFile));
    await entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
      
    final tempWaitQueue = <BiliDownloadEntryInfo>[...waitDownloadQueue, entry];
    waitDownloadQueue.assignAll(tempWaitQueue.toSet().toList());
    
    if (curDownload.value?.status.isDownloading != true &&
        !_isBatchProcessing.value) {
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
    final pageDir = Directory(
      path.join(await _getDownloadPath(), dirName, pageDirName),
    );
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    return _lock.synchronized(() async {
      try {
        await _getDownloadPath();
      } catch (e) {
        await toggleAllTasks();
        SmartDialog.showToast('Storage Lost - Please reselect directory');
        entry.downloadedBytes = 0;
        flagNotifier.refresh();
        return;
      }
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
      if (!_isBatchProcessing.value) {
        waitDownloadQueue.refresh();
      }
      await _startDownload(entry);
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) {
      return false;
    }
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

  Future<bool> _downloadCover({required BiliDownloadEntryInfo entry}) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      final file = (await CacheManager.manager.getFileFromCache(entry.cover))
          ?.file;
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

  Future<void> _startDownload(BiliDownloadEntryInfo entry) async {
    try {
      if (!await downloadDanmaku(entry: entry)) {
        return;
      }

      _updateCurStatus(DownloadStatus.getPlayUrl);

      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );

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
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    final tempFile = File('${entryJsonFile.path}.tmp');
    await tempFile.writeAsString(jsonEncode(entry.toJson()), flush: true);
    tempFile.renameSync(entryJsonFile.path);
  }

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      if (progress == 0 && total != 0) {
        _updateBiliDownloadEntryJson(entry..totalBytes = total);
      }
      entry
        ..downloadedBytes = progress
        ..status = DownloadStatus.downloading;
      if (!_isBatchProcessing.value) {
        curDownload.refresh();
      }
    }
  }

  void _onDone([Object? error]) {
    if (error != null) {
      _updateCurStatus(_downloadManager?.status ?? DownloadStatus.pause);
      nextDownload();
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
        nextDownload();
      }
    }
  }

  Future<void> _completeDownload() async {
    final entry = curDownload.value;
    if (entry == null) {
      return;
    }
    entry
      ..downloadedBytes = entry.totalBytes
      ..isCompleted = true;
    await _migrateToSafIfNeeded(entry);
    await _updateBiliDownloadEntryJson(entry);
    waitDownloadQueue.remove(entry);
    downloadList.insert(0, entry);
    flagNotifier.refresh();
    _curCid = null;
    curDownload.value = null;
    _downloadManager = null;
    _audioDownloadManager = null;
    nextDownload();
  }

  /// Moves the finished media artifacts into the custom SAF directory.
  ///
  /// Only runs when the storage type is "自定义目录(SAF)" (downloadDirType == 2).
  /// Each final artifact (`0.mp4`, or `video.m4s` + `audio.m4s`) is copied into
  /// the SAF tree via the native `saveToSafDirectory` channel. On success the
  /// private-storage temp file is deleted and the resulting content URIs are
  /// recorded on [entry] (persisted via `entry.json`).
  Future<void> _migrateToSafIfNeeded(BiliDownloadEntryInfo entry) async {
    if (!Platform.isAndroid) return;
    final type = GStorage.setting.get(
      SettingBoxKey.downloadDirType,
      defaultValue: 0,
    ) as int;
    if (type != 2) return;
    final safUri = Pref.downloadSafUri;
    if (safUri == null || safUri.isEmpty) return;

    final typeTag = entry.typeTag;
    if (typeTag == null || typeTag.isEmpty) return;

    final videoDir = Directory(path.join(entry.entryDirPath, typeTag));
    if (!videoDir.existsSync()) return;

    await videoPlayerServiceHandler?.stop();
    await PlPlayerController.instance?.videoPlayerController?.stop();

    final artifacts = <String>[];
    final single = File(path.join(videoDir.path, PathUtils.videoNameType1));
    if (single.existsSync()) {
      artifacts.add(single.path);
    } else {
      final video = File(path.join(videoDir.path, PathUtils.videoNameType2));
      final audio = File(path.join(videoDir.path, PathUtils.audioNameType2));
      if (video.existsSync()) artifacts.add(video.path);
      if (audio.existsSync()) artifacts.add(audio.path);
    }
    if (artifacts.isEmpty) return;

    final targetDir = _relativePath(videoDir.path);
    final uris = <String, String>{};
    for (final filePath in artifacts) {
      try {
        final uri = await DownloadManager.saveToSafDirectory(
          path: filePath,
          targetDir: targetDir,
        );
        if (uri != null && uri.isNotEmpty) {
          uris[path.basename(filePath)] = uri;
          final file = File(filePath);
          if (file.existsSync()) {
            await file.tryDel();
          }
        }
      } catch (e) {
        // Keep the local file so a failed SAF copy never loses the download.
      }
    }
    if (uris.isNotEmpty) {
      entry.safFileUris = uris;
    }
  }

  String _relativePath(String absPath) {
    var relative = absPath.startsWith(downloadPath)
        ? absPath.substring(downloadPath.length)
        : path.basename(absPath);
    relative = relative.replaceAll('\\', '/');
    while (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    return relative;
  }

  void nextDownload() {
    final index = waitDownloadQueue.indexWhere(
      (e) => e.status == DownloadStatus.wait,
    );
    if (index != -1) {
      startDownload(waitDownloadQueue[index]);
    }
  }

  Future<void> redownload(BiliDownloadEntryInfo entry) async {
    if (curDownload.value?.cid == entry.cid) {
      await cancelDownload(isDelete: true, downloadNext: true);
    }
    
    final typeTag = entry.typeTag;
    if (typeTag != null) {
      final videoDir = Directory(path.join(entry.entryDirPath, typeTag));
      if (videoDir.existsSync()) {
        try {
          await videoDir.delete(recursive: true);
        } catch (e, st) { print("Error reading entry: $e\n$st"); }
      }
    }
    
    entry.isCompleted = false;
    entry.downloadedBytes = 0;
    entry.status = DownloadStatus.wait;
    entry.safFileUris = null;
    
    await _updateBiliDownloadEntryJson(entry);
    
    if (downloadList.contains(entry)) {
      downloadList.remove(entry);
    }
    if (!waitDownloadQueue.contains(entry)) {
      waitDownloadQueue.add(entry);
    }
    flagNotifier.refresh();
    nextDownload();
  }

  /// Deletes this entry's artifacts from the SAF tree.
  ///
  /// Two independent actions, because neither alone is sufficient:
  ///   * per-file delete via each `content://` URI recorded in
  ///     [BiliDownloadEntryInfo.safFileUris] — the only reliable handle on
  ///     files this device actually wrote;
  ///   * a recursive delete of the artifact directory, addressed as tree URI
  ///     plus relative path — the only way to reach artifacts of legacy
  ///     entries whose `safFileUris` is null, leftover `.<name>.tmp` files,
  ///     and the empty directory shells per-file deletion leaves behind.
  ///
  /// Returns true only when the tree no longer holds the artifacts. A false
  /// return is not fatal: the local copy is deleted either way and the entry is
  /// removed from the lists, because leaving it would let `_readDownloadList`
  /// resurrect an entry whose URIs no longer resolve.
  Future<bool> _deleteSafArtifacts(BiliDownloadEntryInfo entry) async {
    final safUri = Pref.downloadSafUri;
    if (safUri == null || safUri.isEmpty) return false;

    var ok = true;

    final uris = entry.safFileUris?.values.toList(growable: false) ??
        const <String>[];
    for (final uri in uris) {
      try {
        final res = await DownloadManager.deleteSafFile(uri);
        if (res != true) ok = false;
      } catch (e) {
        ok = false;
        if (kDebugMode) debugPrint('deleteSafFile failed: $e');
      }
    }

    final relative = _relativePath(entry.entryDirPath);
    if (relative.isNotEmpty) {
      try {
        final res = await DownloadManager.deleteSafPath(
          treeUri: safUri,
          relativePath: relative,
        );
        if (res != true) ok = false;
      } catch (e) {
        ok = false;
        if (kDebugMode) debugPrint('deleteSafPath($relative) failed: $e');
      }
    }

    return ok;
  }

  /// Deletes the SAF-side directory shell for one local page directory.
  Future<bool> _deleteSafPathFor(String pageDirPath) async {
    final safUri = Pref.downloadSafUri;
    if (safUri == null || safUri.isEmpty) return false;
    final relative = _relativePath(pageDirPath);
    if (relative.isEmpty) return false;
    try {
      return await DownloadManager.deleteSafPath(
            treeUri: safUri,
            relativePath: relative,
          ) ==
          true;
    } catch (e) {
      if (kDebugMode) debugPrint('deleteSafPath($relative) failed: $e');
      return false;
    }
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) async {
    if (curDownload.value?.cid == entry.cid) {
      await cancelDownload(isDelete: true, downloadNext: downloadNext);
    }

    // Mark as deleting
    entry.status = DownloadStatus.pause;
    flagNotifier.refresh();

    await videoPlayerServiceHandler?.stop();
    await PlPlayerController.instance?.videoPlayerController?.stop();

    // SAF first, then local unconditionally. Gating the local cleanup on the
    // SAF result used to be safe only because the SAF delete never succeeded;
    // once it does, `entry.json` would survive in app-private storage, the next
    // `_readDownloadList` would read it back, and the entry the user just
    // deleted would reappear — unplayable, because its URIs are gone.
    final deletedViaSaf = await _deleteSafArtifacts(entry);

    bool deleted = true;
    final downloadDir = Directory(entry.pageDirPath);
    if (downloadDir.existsSync()) {
      if (!await downloadDir.lengthGte(2)) {
        await downloadDir.tryDel(recursive: true);
        deleted = !downloadDir.existsSync();
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
          deleted = !entryDir.existsSync();
        }
      }
    }

    // Only remove from UI if actually deleted from disk (or if it was already missing)
    if (deleted || deletedViaSaf) {
      if (removeList) {
        downloadList.remove(entry);
      }
      if (removeQueue) {
        waitDownloadQueue.remove(entry);
      }
    } else {
      entry.status = DownloadStatus.failDownload; // Mark as failed so user knows
    }

    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    await videoPlayerServiceHandler?.stop();
    await PlPlayerController.instance?.videoPlayerController?.stop();

    // Look the page's entries up by path rather than changing the signature:
    // all three call sites (`controller.dart`, `detail/view.dart`) deal in
    // paths, and passing entries in would reach into the UI layer for no gain.
    // The scan is O(downloadList), which is tens of entries.
    var safOk = true;
    for (final entry in <BiliDownloadEntryInfo>[
      ...downloadList,
      ...waitDownloadQueue,
    ].where((e) => e.pageDirPath == pageDirPath)) {
      if (!await _deleteSafArtifacts(entry)) safOk = false;
    }
    if (!await _deleteSafPathFor(pageDirPath)) safOk = false;

    final dir = Directory(pageDirPath);
    await dir.tryDel(recursive: true);
    var success = !dir.existsSync();
    if (safOk) success = true;

    if (success) {
      downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    }
    
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
