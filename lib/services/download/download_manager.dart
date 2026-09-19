import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:dio/dio.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

class DownloadManager {
  static const MethodChannel _channel = MethodChannel('com.piliplus/download');

  static Future<void> init() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasNet = !connectivityResult.contains(ConnectivityResult.none);
      final isCellular = connectivityResult.contains(ConnectivityResult.mobile);
      final allowCellular = Pref.allowCellularDownload;
      
      if (hasNet && (!isCellular || allowCellular)) {
        await _channel.invokeMethod('resumeFailedTasks');
      }
    } catch (e) {
      // print('DownloadManager init error: $e');
    }
  }

  static Future<void> startDownload(String url, String savePath) async {
    try {
      await _channel.invokeMethod('startDownload', {
        'url': url,
        'savePath': savePath,
      });
    } catch (e) {
      // error handling
    }
  }

  static Future<void> pauseDownload() async {
    try {
      await _channel.invokeMethod('pauseDownload');
    } catch (e) {
      // error handling
    }
  }

  static Future<void> resumeAll() async {
    try {
      await _channel.invokeMethod('resumeAll');
    } catch (e) {
      // error handling
    }
  }

  /// Copies a finished download artifact into the user-selected SAF directory.
  ///
  /// [path] is the absolute path of the source file in the app-private storage.
  /// [targetDir] is the relative directory (e.g. `avid/c_cid/typeTag`) created
  /// under the SAF tree. Returns the content:// URI of the copied file, or null
  /// on failure (in which case the caller keeps the local file).
  static Future<String?> saveToSafDirectory({
    required String path,
    required String targetDir,
  }) async {
    try {
      return await _channel.invokeMethod<String>('saveToSafDirectory', {
        'path': path,
        'targetDir': targetDir,
      });
    } catch (e) {
      return null;
    }
  }

  /// Resolves a SAF [contentUri] (content://...) to a real file path that
  /// libmpv / media_kit can open directly.
  ///
  /// Uses the mpv-android /proc/self/fd trick:
  ///   1. Open the URI with ContentResolver → get a file descriptor (fd).
  ///   2. Resolve `/proc/self/fd/<fd>` symlink → real absolute path.
  ///   3. If the symlink cannot be resolved (rare, e.g. strict SELinux),
  ///      the Kotlin side keeps the fd open and returns `/proc/self/fd/<fd>`
  ///      which libmpv can still read via the open fd.
  ///
  /// Call [clearSafPfds] after playback ends to release any held fds.
  static Future<String?> resolveContentUri(String contentUri) async {
    try {
      return await _channel.invokeMethod<String>(
        'resolveContentUriToPath',
        {'uri': contentUri},
      );
    } catch (_) {
      return null;
    }
  }

  /// Releases file descriptors held by [resolveContentUri] for the
  /// `/proc/self/fd/<n>` fallback case. Call after playback ends.
  static Future<void> clearSafPfds() async {
    try {
      await _channel.invokeMethod<void>('clearSafPfds');
    } catch (_) {}
  }

  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
  }) {
    task = _start();
  }

  Future<void> _start() async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    Future<void> onError(Object e, {bool delete = false}) async {
      try {
        await sink.close();
      } catch (_) {}
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
        if (delete && file.existsSync()) {
          await file.tryDel();
        }
      }
      onDone(e);
    }

    Response<ResponseBody> response;
    try {
      response = await Request.http11Dio.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null &&
              (status == 416 || (status >= 200 && status < 300)),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      await onError(e, delete: false);
      return;
    }

    if (response.statusCode == 416) {
      await sink.close();
      final contentRange = response.headers.value('content-range');
      int? serverTotal;
      if (contentRange != null) {
        final match = RegExp(r'bytes\s+\*/(\d+)').firstMatch(contentRange);
        if (match != null) {
          serverTotal = int.tryParse(match.group(1)!);
        }
      }
      
      if (received > 0 && (serverTotal == null || received >= serverTotal)) {
        _status = DownloadStatus.completed;
        onDone();
        return;
      }
      
      if (file.existsSync()) {
        await file.tryDel();
      }
      await onError(Exception('HTTP 416: Local offset $received invalid. Cache cleared.'), delete: false);
      return;
    }

    final data = response.data!;
    final contentLength = data.contentLength + received;

    if (received == 0) {
      onReceiveProgress?.call(0, contentLength);
    }

    int? last;
    try {
      await for (final chunk in data.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (last != now) {
          last = now;
          onReceiveProgress?.call(received, contentLength);
        }
      }
      await sink.close();
      if (contentLength > 0 && received < contentLength) {
        throw Exception('Download incomplete');
      }
      _status = DownloadStatus.completed;
      onDone();
    } catch (e) {
      await onError(e);
      return;
    }
  }

  Future<void> cancel({required bool isDelete}) {
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel();
    }
    return task;
  }
}
