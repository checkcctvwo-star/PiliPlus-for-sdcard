import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

class DownloadManager {
  static const MethodChannel _channel = MethodChannel('com.piliplus/download');

  /// 混流音视频（video.m4s + audio.m4s -> 0.mp4）
  static Future<bool> mergeDashMedia({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    try {
      final res = await _channel.invokeMethod<bool>('mergeDashMedia', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'outputPath': outputPath,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 获取外置物理 SD 卡路径
  static Future<String?> getExternalSDCardPath() async {
    try {
      return await _channel.invokeMethod<String>('getExternalSDCardPath');
    } catch (_) {
      return null;
    }
  }

  /// 将暂存目录中的条目提交到目标目录（POSIX 或 SAF）
  static Future<bool> commitStagingEntry({
    required String stagingEntryPath,
    required int targetType,
    required String targetBaseDir,
    required String relativePath,
  }) async {
    try {
      final res = await _channel.invokeMethod<bool>('commitStagingEntry', {
        'stagingEntryPath': stagingEntryPath,
        'targetType': targetType,
        'targetBaseDir': targetBaseDir,
        'relativePath': relativePath,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 扫描 SAF 树形目录
  static Future<List<Map<String, dynamic>>> scanSafEntries(String uri) async {
    try {
      final List<dynamic>? res = await _channel.invokeListMethod<dynamic>(
        'scanSafEntries',
        {'uri': uri},
      );
      if (res != null) {
        return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  /// 计算目录大小（支持 POSIX 路径和 content:// SAF 路径）
  static Future<int> calculateDirSize(String path) async {
    try {
      final res = await _channel.invokeMethod<int>('calculateDirSize', {
        'path': path,
      });
      return res ?? 0;
    } catch (_) {
      return 0;
    }
  }


  /// 初始化网络监听并恢复失败的任务
  static Future<void> init() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasNet = !connectivityResult.contains(ConnectivityResult.none);
      final isCellular = connectivityResult.contains(ConnectivityResult.mobile);
      final allowCellular = GStorage.setting.get(
        'allowCellularDownload',
        defaultValue: false,
      ) as bool;

      if (hasNet && (!isCellular || allowCellular)) {
        await _channel.invokeMethod('resumeFailedTasks');
      }
    } catch (_) {}
  }

  static Future<void> startDownload(String url, String savePath) async {
    try {
      await _channel.invokeMethod('startDownload', {
        'url': url,
        'savePath': savePath,
      });
    } catch (_) {}
  }

  static Future<void> pauseDownload() async {
    try {
      await _channel.invokeMethod('pauseDownload');
    } catch (_) {}
  }

  static Future<void> stopAll() async {
    try {
      await _channel.invokeMethod('pauseAll');
    } catch (_) {}
  }

  static Future<void> resumeAll() async {
    try {
      await _channel.invokeMethod('resumeAll');
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getUnfinishedTasks() async {
    try {
      final List<dynamic>? result =
          await _channel.invokeListMethod<dynamic>('getUnfinishedTasks');
      if (result != null) {
        return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<String?> saveToSafDirectory({
    required String path,
    required String targetDir,
  }) async {
    try {
      return await _channel.invokeMethod<String>('saveToSafDirectory', {
        'path': path,
        'targetDir': targetDir,
      });
    } catch (_) {
      return null;
    }
  }

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

  static Future<int?> openSafFd(String contentUri) async {
    try {
      return await _channel.invokeMethod<int>(
        'openSafFd',
        {'uri': contentUri},
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSafPfds() async {
    try {
      await _channel.invokeMethod<void>('clearSafPfds');
    } catch (_) {}
  }

  static Future<bool> deleteSafFile(String uri) async {
    try {
      final res =
          await _channel.invokeMethod<bool>('deleteSafFile', {'uri': uri});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<String>> scanSafDirectory(String uri) async {
    try {
      final List<dynamic>? res = await _channel.invokeListMethod<String>(
        'scanSafDirectory',
        {'uri': uri},
      );
      if (res != null) {
        return res.cast<String>();
      }
    } catch (_) {}
    return [];
  }

  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;
  String? etag;
  String? lastModified;
  String? validatorUrl;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
    this.etag,
    this.lastModified,
    this.validatorUrl,
  }) {
    task = download();
  }

  Future<void> download() async {
    int received = 0;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    Future<void> onError(Object e, {bool delete = false}) async {
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
        if (delete && file.existsSync()) {
          await file.tryDel();
        }
      }
      onDone(e);
    }

    // 粘性 If-Range 校验器与 Range 头部构建
    final headers = <String, dynamic>{
      'Accept-Encoding': 'identity',
    };
    if (received > 0) {
      headers['range'] = 'bytes=$received-';
      if (validatorUrl == url) {
        final validator = etag ?? lastModified;
        if (validator != null && validator.isNotEmpty) {
          headers['If-Range'] = validator;
        }
      }
    }

    Response<ResponseBody> response;
    try {
      response = await Request.http11Dio.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: headers,
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
    } catch (e) {
      await onError(e, delete: false);
      return;
    }

    // HTTP 416 处理：若 received == serverTotal 则智能标记完成；若越界或损坏且 received > 0 则重置切片
    if (response.statusCode == 416) {
      final contentRange = response.headers.value('content-range');
      int? serverTotal;
      if (contentRange != null) {
        final match =
            RegExp(r'bytes\s+(?:\*|\d+-\d+)/(\d+)').firstMatch(contentRange);
        if (match != null) {
          serverTotal = int.tryParse(match.group(1)!);
        }
      }

      if (received > 0 && serverTotal != null && received == serverTotal) {
        _status = DownloadStatus.completed;
        onReceiveProgress?.call(received, received);
        onDone();
        return;
      }

      if (file.existsSync()) {
        await file.tryDel();
      }
      etag = null;
      lastModified = null;
      validatorUrl = null;
      await onError(
        Exception('HTTP 416: Local offset $received invalid. Slice reset.'),
        delete: false,
      );
      return;
    }

    // 记录 ETag 与 Last-Modified 校验器
    final respEtag =
        response.headers.value('etag')?.replaceAll(RegExp(r'^W/'), '');
    final respLastModified = response.headers.value('last-modified');
    if (respEtag != null && respEtag.isNotEmpty) {
      etag = respEtag;
    }
    if (respLastModified != null && respLastModified.isNotEmpty) {
      lastModified = respLastModified;
    }
    validatorUrl = url;

    final isPartial = response.statusCode == 206;
    if (!isPartial && received > 0) {
      // 200 OK: 服务器未应用 Range，重新从头写入
      received = 0;
    }

    final sink = file.openWrite(
      mode: (!isPartial || received == 0)
          ? FileMode.writeOnly
          : FileMode.writeOnlyAppend,
    );

    final data = response.data!;
    final dataContentLength = data.contentLength;
    final contentLength = (dataContentLength >= 0)
        ? dataContentLength + received
        : -1;

    if (received == 0 && contentLength > 0) {
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
          onReceiveProgress?.call(
            received,
            contentLength > 0 ? contentLength : received,
          );
        }
      }
      await sink.flush();
      await sink.close();

      // 终态强校验：数据读取完成后校验 contentLength > 0 && received < contentLength 时抛出 Exception('Download incomplete')，防止残缺切片被放行
      if (contentLength > 0 && received < contentLength) {
        throw Exception('Download incomplete');
      }

      _status = DownloadStatus.completed;
      onDone();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
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
