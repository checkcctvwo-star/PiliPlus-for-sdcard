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

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}

/// A [DataSource] whose video/audio paths have already been resolved from SAF
/// content:// URIs to real absolute paths (or /proc/self/fd/<n> fallback paths)
/// via [DownloadManager.resolveContentUri]. Treated like [FileSource] by the
/// player controller (no network caching, no refresh, etc.).
class SafResolvedSource extends DataSource {
  SafResolvedSource({
    required super.videoSource,
    super.audioSource,
  });
}
