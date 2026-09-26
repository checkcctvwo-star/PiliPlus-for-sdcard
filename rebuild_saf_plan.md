# 重构 SAF 下载与 UI 修复计划

## 任务 1: 修复致命编译错误 (B1 & DownloadStatus)
- 目标：`lib/services/download/download_manager.dart` 和 `lib/pages/download/view.dart`
- 说明：
  1. 修复 `allowCellularDownload` 未定义的错误（在 `SettingBoxKey` 添加 getter 扩展，或者将其替换为正确的已有配置读取法，如 `Pref.isCellularDownload` 如果存在的话，先检索）。
  2. 修复 `view.dart` 中 `DownloadStatus` 找不到的错误（应该导入 `download_service.dart` 或正确的文件）。

## 任务 2: 重新设计 SAF 迁移架构 (B2 & H组) - 核心
- 目标：`video_downloader.dart` (或实际下载 M3U8 及 FFmpeg 合并的地方) 及原生 MethodChannel。
- 说明：
  完全抛弃 Aria 的 `@Download.onTaskComplete` 迁移。
  当 FFmpeg 合并完成（或普通单文件下载完成）时，如果当前存储设置为“自定义目录(SAF)”，则在 Flutter 侧通过 MethodChannel 传入最终产物的文件路径，由原生使用 `DocumentFile` 创建新文件并拷贝，并用 `.use{}` 关闭流，最后将新路径返回，Flutter 侧删除原私有目录下的临时文件并更新数据库。

## 任务 3: 网络恢复逻辑接入与修正 (R1)
- 目标：`main.dart` 或 `download_service.dart`
- 说明：
  将 `DownloadManager.init()` 正确接入启动流程。确保先加载原生保存的列表，再同步到 Flutter。修改底层原生 `resumeFailedTasks`，只重试 Fail 和 Wait 状态。

## 任务 4: 全部暂停按钮互斥与 UI 闪烁修复 (C1, C2)
- 目标：`download_service.dart`
- 说明：
  在 `isBatchProcessing` 期间，拦截单体 `_startDownload` 和 `_onReceive` 回调，防止中间态。

