import 'dart:io' show File;

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;
  final Map<String, String>? safFileUris;

  factory FileSource({
    required String dir,
    required bool isMp4,
    required bool hasDashAudio,
    required String typeTag,
    Map<String, String>? safFileUris,
  }) {
    if (safFileUris != null && safFileUris.isNotEmpty) {
      final mp4Uri = safFileUris[PathUtils.videoNameType1] ??
          safFileUris['$typeTag/${PathUtils.videoNameType1}'] ??
          safFileUris.entries.firstWhereOrNull((e) => e.key.endsWith(PathUtils.videoNameType1))?.value;
      final videoM4sUri = safFileUris[PathUtils.videoNameType2] ??
          safFileUris['$typeTag/${PathUtils.videoNameType2}'] ??
          safFileUris.entries.firstWhereOrNull((e) => e.key.endsWith(PathUtils.videoNameType2))?.value;
      final audioM4sUri = safFileUris[PathUtils.audioNameType2] ??
          safFileUris['$typeTag/${PathUtils.audioNameType2}'] ??
          safFileUris.entries.firstWhereOrNull((e) => e.key.endsWith(PathUtils.audioNameType2))?.value;

      if (mp4Uri != null) {
        return FileSource._(
          dir: dir,
          isMp4: true,
          videoSource: mp4Uri,
          audioSource: null,
          safFileUris: safFileUris,
        );
      } else if (videoM4sUri != null) {
        return FileSource._(
          dir: dir,
          isMp4: false,
          videoSource: videoM4sUri,
          audioSource: hasDashAudio ? audioM4sUri : null,
          safFileUris: safFileUris,
        );
      }
    }

    final type1InRoot = path.join(dir, PathUtils.videoNameType1);
    final type1InTag = path.join(dir, typeTag, PathUtils.videoNameType1);
    final videoM4s = path.join(dir, typeTag, PathUtils.videoNameType2);
    final audioM4s = path.join(dir, typeTag, PathUtils.audioNameType2);

    final hasType1Root = File(type1InRoot).existsSync();
    final hasType1Tag = File(type1InTag).existsSync();
    final hasVideoM4s = File(videoM4s).existsSync();
    final hasAudioM4s = File(audioM4s).existsSync();

    // 严谨决策：只有当 0.mp4 真实物理存在时，才作为单体 MP4 播放
    if (hasType1Root) {
      return FileSource._(
        dir: dir,
        isMp4: true,
        videoSource: type1InRoot,
        audioSource: null,
        safFileUris: safFileUris,
      );
    } else if (hasType1Tag) {
      return FileSource._(
        dir: dir,
        isMp4: true,
        videoSource: type1InTag,
        audioSource: null,
        safFileUris: safFileUris,
      );
    } else if (hasVideoM4s) {
      // 遗留未混流切片：回退为标准双轨 DASH 播放，坚决防止黑屏无声
      return FileSource._(
        dir: dir,
        isMp4: false,
        videoSource: videoM4s,
        audioSource: hasAudioM4s ? audioM4s : (hasDashAudio ? audioM4s : null),
        safFileUris: safFileUris,
      );
    }

    // 兜底逻辑（例如 SAF content:// 协议或特殊挂载）
    final fallbackIsMp4 = isMp4;
    final isContentUri = dir.startsWith('content:/');
    final vSource = fallbackIsMp4
        ? (isContentUri ? '$dir/$typeTag/${PathUtils.videoNameType1}' : type1InTag)
        : (isContentUri ? '$dir/$typeTag/${PathUtils.videoNameType2}' : path.join(dir, typeTag, PathUtils.videoNameType2));
    final aSource = fallbackIsMp4 || !hasDashAudio
        ? null
        : (isContentUri ? '$dir/$typeTag/${PathUtils.audioNameType2}' : path.join(dir, typeTag, PathUtils.audioNameType2));

    return FileSource._(
      dir: dir,
      isMp4: fallbackIsMp4,
      videoSource: vSource,
      audioSource: aSource,
      safFileUris: safFileUris,
    );
  }

  FileSource._({
    required this.dir,
    required this.isMp4,
    required super.videoSource,
    required super.audioSource,
    this.safFileUris,
  });
}

