import 'dart:io' show File;

import 'package:PiliPlus/utils/path_utils.dart';
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

  factory FileSource({
    required String dir,
    required bool isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) {
    final type1InRoot = path.join(dir, PathUtils.videoNameType1);
    final type1InTag = path.join(dir, typeTag, PathUtils.videoNameType1);
    final hasType1Root = File(type1InRoot).existsSync();
    final hasType1Tag = File(type1InTag).existsSync();
    final effectiveIsMp4 = isMp4 || hasType1Root || hasType1Tag;

    final videoPath = hasType1Root
        ? type1InRoot
        : (hasType1Tag || effectiveIsMp4
            ? type1InTag
            : path.join(dir, typeTag, PathUtils.videoNameType2));

    return FileSource._(
      dir: dir,
      isMp4: effectiveIsMp4,
      videoSource: videoPath,
      audioSource: effectiveIsMp4 || !hasDashAudio
          ? null
          : path.join(dir, typeTag, PathUtils.audioNameType2),
    );
  }

  FileSource._({
    required this.dir,
    required this.isMp4,
    required super.videoSource,
    required super.audioSource,
  });
}

