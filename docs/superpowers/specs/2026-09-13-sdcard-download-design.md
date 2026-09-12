# PiliPlus 离线下载重构与 SD 卡存储支持架构设计

## 1. 目标
* 增加外置 SD 卡下载目录选择支持（自动侦测与容量展示）。
* 解决息屏下载导致的视频损坏/无法播放问题。
* 支持系统前台保活（Foreground Service）和原生通知栏进度条。
* 支持断点续传（冷启动静默恢复）、自动重试。
* 搭建 CI/CD (GitHub Actions) 输出可与正式版共存的 Debug 测试包。

## 2. 架构选型
基于 Flutter 混合开发架构，采用 **Aria (Java/Kotlin) + Flutter MethodChannel** 桥接方案。
* **下载核心 (原生)**: 使用 Aria 库负责所有的网络请求、分块写入、MD5 校验和断点记录。
* **通信层**: 通过自定义的 Flutter MethodChannel (`com.piliplus/download`) 将下载指令（开始、暂停、恢复）下发，并通过 EventChannel 接收进度流和状态。
* **持久化策略**: 使用原生 `getExternalFilesDir()` 以保证符合“应用卸载，文件随之删除”的特性。

## 3. 功能细节与交互设计

### 3.1 存储路径与 SD 卡检测 (UI 交互)
* **默认路径**: 默认下载到设备内部存储。
* **SD 卡挂载检测**: 当用户在设置页面打开“存储选项”时，调用原生 API（如 `ContextCompat.getExternalFilesDirs` 和 `StorageManager`）实时侦测 SD 卡挂载状态。
* **可用性与容量展示**:
  * 若 SD 卡挂载正常且无报错，才允许用户选择 SD 卡。
  * 调用原生 `StatFs` 接口计算并在 UI 上展示 SD 卡的**总容量**和**可用容量**（如：`可用 45GB / 总共 128GB`）。
  * 若检测异常，给出明确的 UI 提示。

### 3.2 息屏保活与通知栏 (后台机制)
* **前台服务 (Foreground Service)**: 针对鸿蒙和 Android Doze 模式，下载任务开始时拉起前台服务，提升进程 OOM_ADJ 优先级，避免被系统误杀。
* **进度通知**: 采用 Android 官方原生的水平进度条 (`NotificationCompat.Builder.setProgress`)，放弃自定义布局，确保在鸿蒙魔改 UI 下百分百兼容不卡顿。

### 3.3 断点续传与防损坏机制
* **防损坏写入**: 由 Aria 引擎接管底层 I/O，使用 RandomAccessFile 并强制落盘 (`getFD().sync()`)。完全杜绝以前因为断网导致 Buffer 未写入而造成的 MP4 结构损坏。
* **静默恢复 (Silent Resume)**: App 每次冷启动时，Flutter 端向原生端发送全局恢复指令。自动找回并静默恢复所有因强杀而异常中断的任务，无需用户手动到下载管理界面点击“继续”。

### 3.4 CI/CD 自动化构建与测试包共存
* **测试包隔离 (共存机制)**: 在 `android/app/build.gradle` 的 `debug` 分支中配置 `applicationIdSuffix ".debug"`。使测试版包名异于正式版，实现同一台设备同时安装正式版和调试版。
* **自动打包流程**: 在根目录新增 `.github/workflows/android_debug_build.yml`，在关键节点 (Push) 自动触发云端构建 APK。

## 4. 依赖说明
- 原生层需要引入 `com.arialyy.aria:core:3.8.16`（或其他最新稳定版本）。
- 需在 AndroidManifest 声明 `FOREGROUND_SERVICE` 权限。
