import 'dart:async';

import 'package:PiliPlus/common/widgets/appbar/appbar.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/pages/download/download/controller.dart';
import 'package:PiliPlus/pages/download/download/widgets/page.dart';
import 'package:PiliPlus/pages/download/download/widgets/season.dart';
import 'package:PiliPlus/pages/download/download_action_mixin.dart';
import 'package:PiliPlus/pages/download/downloading/view.dart';
import 'package:PiliPlus/pages/download/search/view.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with GridMixin, BaseDownloadActionMixin<DownloadPage, DownloadSeasonInfo> {
  final _progress = ChangeNotifier();
  final _controller = Get.put(DownloadController());

  @override
  final downloadService = Get.find<DownloadService>();

  @override
  BaseMultiSelectMixin<DownloadSeasonInfo> get multiSelectCtr => _controller;

  @override
  void initState() {
    super.initState();
    // 每次进入离线缓存界面时，自动在后台静默同步一次存储目录与自愈识别
    WidgetsBinding.instance.addPostFrameCallback((_) {
      downloadService.rescanStorageAndRecover();
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Future<void> onUpdate(
    Future<bool> Function(BiliDownloadEntryInfo e) toElement,
  ) async {
    if (checkUpdateCount(_controller.checkedCount)) return;

    bool dismiss = false;
    SmartDialog.showLoading(
      onDismiss: () {
        dismiss = true;
        _controller.handleSelect();
      },
    );

    bool isSuccess = true;
    for (final chunk in _controller.allChecked.mapChunked(
      kUpdateConcurrency,
      (season) async {
        bool isSuccess = true;
        for (final chunk in season.pages.mapChunked(
          kUpdateConcurrency,
          (page) async {
            bool isSuccess = true;
            for (final chunk in page.entries.mapChunked(
              kUpdateConcurrency,
              toElement,
            )) {
              final res = await Future.wait(chunk);
              if (res.any((e) => !e)) isSuccess = false;
              if (dismiss) break;
            }
            return isSuccess;
          },
        )) {
          final res = await Future.wait(chunk);
          if (res.any((e) => !e)) isSuccess = false;
          if (dismiss) break;
        }
        return isSuccess;
      },
    )) {
      final res = await Future.wait(chunk);
      if (res.any((e) => !e)) isSuccess = false;
      if (dismiss) break;
    }

    toastUpdateResult(dismiss, isSuccess);
  }

  Future<void> _updateSeasonDm(DownloadSeasonInfo seasonInfo) async {
    if (checkUpdateCount(
      seasonInfo.pages.fold(0, (a, b) => a + b.entries.length),
    )) {
      return;
    }

    bool dismiss = false;
    SmartDialog.showLoading(onDismiss: () => dismiss = true);

    bool isSuccess = true;

    for (final page in seasonInfo.pages) {
      for (final chunk in page.entries.mapChunked(
        kUpdateConcurrency,
        (e) => downloadService.downloadDanmaku(
          entry: e,
          isUpdate: true,
        ),
      )) {
        final res = await Future.wait(chunk);
        if (res.any((e) => !e)) isSuccess = false;
        if (dismiss) break;
      }
    }

    toastUpdateResult(dismiss, isSuccess);
  }

  Future<void> _onRescanCache() async {
    SmartDialog.showLoading(msg: '正在重新扫描存储目录...');
    try {
      final count = await downloadService.rescanStorageAndRecover();
      SmartDialog.dismiss();
      SmartDialog.showToast('扫描完成，已同步 $count 部离线视频');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('扫描出错: $e');
    }
  }

  void _redownloadSelected() {
    final entries = _controller.allChecked
        .expand((season) => season.pages)
        .expand((page) => page.entries)
        .toList();
    if (entries.isEmpty) return;
    showConfirmDialog(
      context: context,
      title: const Text('确定重新下载选中视频？'),
      content: Text('将重新下载选中的 ${entries.length} 个视频并覆盖现有文件'),
      onConfirm: () async {
        SmartDialog.showLoading(msg: '正在重新加入下载队列...');
        await downloadService.redownloadTasks(entries);
        _controller.handleSelect();
        SmartDialog.dismiss();
        SmartDialog.showToast('已重新加入下载队列 (${entries.length})');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return Obx(() {
      final enableMultiSelect = _controller.enableMultiSelect.value;
      return popScope(
        canPop: !enableMultiSelect,
        onPopInvokedWithResult: (didPop, result) {
          if (enableMultiSelect) {
            _controller.handleSelect();
          }
        },
        child: SimpleScaffold(
          appBar: MultiSelectAppBarWidget(
            ctr: _controller,
            actions: [
              updateBtn(),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () {
                  if (_controller.checkedCount == 0) return;
                  _redownloadSelected();
                },
                child: const Text('重新下载'),
              ),
            ],
            child: AppBar(
              title: const Text('离线缓存'),
              actions: [
                IconButton(
                  tooltip: '重新扫描缓存',
                  onPressed: _onRescanCache,
                  icon: const Icon(Icons.sync),
                ),
                Obx(() {
                  final count = downloadService.waitDownloadQueue.length;
                  return IconButton(
                    tooltip: '正在缓存',
                    onPressed: () {
                      Get.to(() => const DownloadingPage());
                    },
                    icon: Badge(
                      isLabelVisible: count > 0,
                      label: Text('$count'),
                      child: const Icon(Icons.downloading_outlined),
                    ),
                  );
                }),
                IconButton(
                  tooltip: '搜索',
                  onPressed: () async {
                    await downloadService.waitForInitialization;
                    if (!mounted) return;
                    Get.to(DownloadSearchPage(progress: _progress));
                  },
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  tooltip: '多选',
                  onPressed: () {
                    if (enableMultiSelect) {
                      _controller.handleSelect();
                    } else {
                      _controller.enableMultiSelect.value = true;
                    }
                  },
                  icon: const Icon(Icons.edit_note),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          body: Padding(
            padding: EdgeInsets.only(left: padding.left, right: padding.right),
            child: CustomScrollView(
              slivers: [
                Obx(() {
                  final entry =
                      downloadService.waitDownloadQueue.firstWhereOrNull(
                        (e) => e.cid == downloadService.curCid,
                      ) ??
                      downloadService.waitDownloadQueue.firstOrNull;
                  if (entry != null) {
                    return SliverMainAxisGroup(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.only(left: 12, bottom: 7, right: 12),
                          sliver: SliverToBoxAdapter(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () => Get.to(() => const DownloadingPage()),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Text(
                                      '正在缓存 (${downloadService.waitDownloadQueue.length})',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    const Spacer(),
                                    Text(
                                      '查看全部',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 110,
                            child: DetailItem(
                              entry: entry,
                              progress: _progress,
                              downloadService: downloadService,
                              showTitle: true,
                              isCurr: true,
                              controller: _controller,
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return const SliverToBoxAdapter();
                }),
                Obx(() {
                  if (_controller.seasons.isNotEmpty) {
                    return SliverMainAxisGroup(
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.only(
                            left: 12,
                            bottom: 7,
                            top: downloadService.waitDownloadQueue.isEmpty
                                ? 0
                                : 7,
                          ),
                          sliver: const SliverToBoxAdapter(
                            child: Text('已缓存视频'),
                          ),
                        ),
                        SliverGrid.builder(
                          gridDelegate: gridDelegate,
                          itemBuilder: (context, index) {
                            final season = _controller.seasons[index];
                            final seasonInfo = season.seasonInfo;
                            final pages = season.pages;

                            if (seasonInfo != null && pages.length > 1) {
                              return SeasonInfoItem(
                                controller: _controller,
                                downloadService: downloadService,
                                seasonInfo: seasonInfo,
                                season: season,
                                enableMultiSelect: enableMultiSelect,
                                progress: _progress,
                                updateSeasonDm: _updateSeasonDm,
                              );
                            }

                            final page = pages.first;
                            if (pages.length == 1 && page.entries.length == 1) {
                              final entry = page.entries.first;
                              return DetailItem(
                                entry: entry,
                                progress: _progress,
                                downloadService: downloadService,
                                showTitle: true,
                                onDelete: () {
                                  downloadService.deleteDownload(
                                    entry: entry,
                                    removeList: true,
                                  );
                                  GStorage.watchProgress.delete(
                                    entry.cid.toString(),
                                  );
                                },
                                checked: season.checked,
                                onSelect: (_) => _controller.onSelect(season),
                                controller: _controller,
                              );
                            }

                            return PageInfoItem(
                              controller: _controller,
                              downloadService: downloadService,
                              seasonInfo: season,
                              pageInfo: page,
                              enableMultiSelect: enableMultiSelect,
                              progress: _progress,
                              updatePageDm: updatePageDm,
                            );
                          },
                          itemCount: _controller.seasons.length,
                        ),
                      ],
                    );
                  }
                  if (downloadService.waitDownloadQueue.isNotEmpty) {
                    return const SliverToBoxAdapter();
                  }
                  return const HttpError();
                }),
                SliverToBoxAdapter(
                  child: SizedBox(height: padding.bottom + 100),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
