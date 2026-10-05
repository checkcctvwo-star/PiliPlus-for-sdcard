import 'dart:io' show Platform;

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

  static String buildShadersAbsolutePath(
    String baseDirectory,
    List<String> shaders,
  ) {
    return shaders
        .map((shader) => path.join(baseDirectory, shader))
        .join(Platform.isWindows ? ';' : ':');
  }
}
