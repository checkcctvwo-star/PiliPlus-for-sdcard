import 'dart:io' show File, Platform;

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

late final String tmpDirPath;

late final String appSupportDirPath;

late String downloadPath;

String get defDownloadPath =>
    path.join(appSupportDirPath, PathUtils.downloadDir);

/// The filesystem path downloads are written to before being migrated into the
/// SAF tree.
///
/// Single definition on purpose: `main.dart` computes it at startup and
/// `extra_settings.dart` must compute the identical directory when the user
/// picks a SAF folder. If the two ever drift, downloads made before a restart
/// land somewhere the next session does not look.
Future<String> safWorkingDir() async {
  final externalStorageDirPath = (await getExternalStorageDirectory())?.path;
  return externalStorageDirPath != null
      ? path.join(externalStorageDirPath, PathUtils.downloadDir)
      : defDownloadPath;
}

abstract final class PathUtils {
  static const videoNameType1 = '0.mp4';
  static const _fileExt = '.m4s';
  static const audioNameType2 = 'audio$_fileExt';
  static const videoNameType2 = 'video$_fileExt';
  static const coverName = 'cover.jpg';
  static const danmakuName = 'danmaku.pb';
  static const downloadDir = 'download';

  /// Whether [file] can be trusted as a decodable image on disk.
  ///
  /// Covers the three states a `cover.jpg` can be left in by an interrupted or
  /// racing SD-card write: missing, present but zero-length, and present with
  /// truncated content. Only the first is caught by `existsSync()`; a
  /// zero-length file passes it and then fails at decode time, which without an
  /// `errorBuilder` renders Flutter's red-cross placeholder.
  ///
  /// Sized content can still be corrupt, so callers must pair this with an
  /// `errorBuilder`; this only rules out the cases decidable from metadata.
  static bool isUsableImageFile(File file) {
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      // SD card reads fail outright when the volume is unmounted or permission
      // is denied (errno=13); treat every throw as "not usable".
      return false;
    }
  }

  static String buildShadersAbsolutePath(
    String baseDirectory,
    List<String> shaders,
  ) {
    return shaders
        .map((shader) => path.join(baseDirectory, shader))
        .join(Platform.isWindows ? ';' : ':');
  }
}
