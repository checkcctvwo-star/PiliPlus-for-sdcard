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
    final effectiveIsMp4 = isMp4 ||
        File(path.join(dir, typeTag, PathUtils.videoNameType1)).existsSync();
    return FileSource._(
      dir: dir,
      isMp4: effectiveIsMp4,
      videoSource: path.join(
        dir,
        typeTag,
        effectiveIsMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
      ),
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

