import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

/// 专用于离线缓存视频的多级抗崩溃封面组件 (5-Tier Cover Image)
/// 依次支持：
/// 1. 应用内部沙盒缓存文件（秒级加载、无权限限制、100% 离线支持）
/// 2. 磁盘 POSIX cover.jpg 文件（附带 errorBuilder 异常拦截防崩溃）
/// 3. SAF Tree DocumentFile 字节直接读取（通过 ContentResolver 穿透 SD 卡权限墙）
/// 4. 远程网络 CDN 图片（通过 CachedNetworkImage 渲染与持久化）
/// 5. 占位缺省图
class DownloadCoverImage extends StatefulWidget {
  const DownloadCoverImage({
    super.key,
    required this.entry,
    required this.width,
    required this.height,
    this.borderRadius = Style.mdRadius,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.cacheHeight,
  });

  final BiliDownloadEntryInfo entry;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  State<DownloadCoverImage> createState() => _DownloadCoverImageState();
}

class _DownloadCoverImageState extends State<DownloadCoverImage> {
  Uint8List? _safBytes;
  bool _safAttempted = false;

  @override
  void initState() {
    super.initState();
    _checkAndLoadSafBytesIfNeeded();
  }

  @override
  void didUpdateWidget(covariant DownloadCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.cid != widget.entry.cid ||
        oldWidget.entry.avid != widget.entry.avid) {
      _safBytes = null;
      _safAttempted = false;
      _checkAndLoadSafBytesIfNeeded();
    }
  }

  void _checkAndLoadSafBytesIfNeeded() {
    final localSandbox = DownloadService.getLocalCoverFile(widget.entry);
    if (!localSandbox.existsSync() && widget.entry.cover.isEmpty) {
      _loadSafBytes();
    }
  }

  Future<void> _loadSafBytes() async {
    if (_safAttempted) return;
    _safAttempted = true;

    final safUri = widget.entry.safFileUris?[PathUtils.coverName] ??
        widget.entry.safFileUris?['cover.jpg'];
    Uint8List? bytes;
    if (safUri != null && safUri.startsWith('content:/')) {
      bytes = await DownloadManager.readSafBytes(safUri);
    }

    if ((bytes == null || bytes.isEmpty) &&
        widget.entry.entryDirPath.isNotEmpty) {
      final posixPath = path.join(widget.entry.entryDirPath, PathUtils.coverName);
      bytes = await DownloadManager.readSafBytes(posixPath);
    }

    if (bytes != null && bytes.isNotEmpty && mounted) {
      setState(() {
        _safBytes = bytes;
      });
      try {
        final localFile = DownloadService.getLocalCoverFile(widget.entry);
        await localFile.writeAsBytes(bytes);
      } catch (_) {}
    }
  }

  Widget _buildFallback(BuildContext context) {
    if (widget.entry.cover.isNotEmpty && widget.entry.cover.startsWith('http')) {
      return NetworkImgLayer(
        src: widget.entry.cover,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        borderRadius: widget.borderRadius,
        cacheWidth: widget.entry.pageData?.cacheWidth,
      );
    }

    _loadSafBytes();

    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.borderRadius,
      ),
      child: Icon(
        Icons.video_library_outlined,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. 如果已从 SAF 成功读取过二进制字节
    if (_safBytes != null && _safBytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.memory(
          _safBytes!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          cacheHeight: widget.cacheHeight,
          colorBlendMode:
              NetworkImgLayer.reduce ? BlendMode.modulate : null,
          color: NetworkImgLayer.reduce
              ? NetworkImgLayer.reduceLuxColor
              : null,
          errorBuilder: (context, error, stackTrace) => _buildFallback(context),
        ),
      );
    }

    // 2. 检查应用内部沙盒缓存文件 (100% 权限安全)
    final localSandbox = DownloadService.getLocalCoverFile(widget.entry);
    if (localSandbox.existsSync()) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.file(
          localSandbox,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          cacheHeight: widget.cacheHeight,
          colorBlendMode:
              NetworkImgLayer.reduce ? BlendMode.modulate : null,
          color: NetworkImgLayer.reduce
              ? NetworkImgLayer.reduceLuxColor
              : null,
          errorBuilder: (context, error, stackTrace) => _buildFallback(context),
        ),
      );
    }

    // 3. 检查 POSIX 路径上的 cover.jpg 文件（附带防崩溃 errorBuilder 回退）
    if (!widget.entry.entryDirPath.startsWith('content://')) {
      final posixCover = File(
        path.join(widget.entry.entryDirPath, PathUtils.coverName),
      );
      if (posixCover.existsSync()) {
        return ClipRRect(
          borderRadius: widget.borderRadius,
          child: Image.file(
            posixCover,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            cacheHeight: widget.cacheHeight,
            colorBlendMode:
                NetworkImgLayer.reduce ? BlendMode.modulate : null,
            color: NetworkImgLayer.reduce
                ? NetworkImgLayer.reduceLuxColor
                : null,
            errorBuilder: (context, error, stackTrace) {
              _loadSafBytes();
              return _buildFallback(context);
            },
          ),
        );
      }
    }

    // 4. 回退至网络 CDN / CachedNetworkImage 或触发 SAF 尝试
    return _buildFallback(context);
  }
}
