# PiliPlus for SDCard - Agent 交接文档 (Handoff V4)

## 1. 项目概况与业务背景

- **仓库路径**: `/home/haoshuai/Linux-AI-project/piliplus-for-sdcard`
- **GitHub 远程**: `https://github.com/checkcctvwo-star/PiliPlus-for-sdcard`
- **上游基准**: 同步至官方最新 `PiliPlus v2.1.6.2` (`b2d6a5bef`)
- **包名与应用名**: `com.example.piliplus.sd` / `PiliPlus SD`
- **版本号**: `2.1.9+7`
- **核心业务痛点解决**:
  1. **平板外置存储视频打不开/黑屏/音画不同步**:
     - 根因分析：Android 11+ SELinux 严限 `untrusted_app`，导致 `media_kit`/`libmpv` 底层 C++ 无法以 POSIX 形式直接打开 SAF `content://` URI；旧版的 `/proc/self/fd` 技巧因 `canonicalPath` 解析导致 PFD 关闭失败；且 DASH 双流（`video.m4s` + `audio.m4s`）使用 `edl://` 播放容易产生音画不同步或缓冲卡死。
     - 终极解决方案：吸收 `happycola233/BiliTools` 工业级实践，采用 16KB 对齐的 FFmpegKit 原生混流引擎，在下载完成后极速合并为单个标准 `0.mp4`。
     - 优先存放于 Android 外部 SD 卡应用专属目录 (`context.getExternalFilesDirs(null)[1]/download`)，获得 **100% 原生 POSIX 读写权限，免去 SAF 性能损耗与权限弹窗**，`libmpv` 毫秒级直启。
  2. **下载切片残缺与网络风控**:
     - 借鉴 BiliTools：引入粘性 If-Range 校验器、HTTP 416 智能判断、Content-Length 终态严格校验。
     - 保持 600ms 串行退避扫描与 V3 去中心化元数据原子写入 (`.tmp` + `flush: true` + rename)。
  3. **无损继承上游 v2.1.6.2 关键特性**:
     - 完整保留 SponsorBlock 片段跳过、UGC/PGC 视频合集离线下载、Season/Episode 增强模型。

---

## 2. 核心架构与落地文件

1. **Android 原生层**:
   - `android/app/build.gradle.kts`:
     - `applicationId = "com.example.piliplus.sd"`
     - `resValue("string", "app_name", "PiliPlus SD")`
     - 依赖 `io.github.jamaismagic.ffmpeg:ffmpeg-kit-main-16kb:6.1.7` (Android 15/16 16KB Page Size 兼容)
     - 依赖 `androidx.documentfile:documentfile:1.0.1`、`me.laoyuyu.aria:core:3.8.16`
     - 签名回退逻辑：缺省证书时采用 debug keystore 兜底，保证 sideload 安装及后续平滑覆盖升级。
   - `android/app/src/main/kotlin/com/example/piliplus/media/MediaMuxerBridge.kt`:
     - 原生 FFmpegKit DASH 混流：`-c copy -shortest -strict unofficial -movflags +faststart`，临时文件原子重命名与临时分片清理。
   - `android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt`:
     - MethodChannel (`com.piliplus/download`) 提供 `mergeDashMedia`、`getExternalSDCardPath`、Aria 任务状态钩子及 SAF 树形结构迁移通道。

2. **Flutter 业务层**:
   - `pubspec.yaml`: 版本号升级为 `2.1.9+7`。
   - `lib/services/download/download_manager.dart`:
     - 粘性 If-Range、416 智能识别、强效 Content-Length 终态校验。
   - `lib/services/download/download_service.dart`:
     - 下载完成后自动触发 `mergeDashMedia` 合并为 `0.mp4`，更新 `entry.mediaType = 1`。
     - 去中心化 `entry.json` 原子写入。
     - 600ms 串行退避深度扫描。
   - `lib/plugin/pl_player/models/data_source.dart`:
     - `FileSource` 增加磁盘自愈检测，若存在 `0.mp4` 则自适应以单流模式秒启播放。
   - `lib/pages/setting/models/extra_settings.dart`:
     - 内部私有存储 / 外置 SD 卡沙盒 / SAF 自定义目录三轨存储选择器与在线无缝迁移。

3. **CI/CD 流水线**:
   - `.github/workflows/android_sdcard_release.yml`:
     - 触发条件：push 到 `main` 分支或 manual workflow_dispatch。
     - 环境：Java 17 Zulu + Flutter pub get + `patch.ps1 android` 补丁注入。
     - 构建：`flutter build apk --release --split-per-abi`。
     - 产物重命名与发布：`softprops/action-gh-release@v2` 自动发布至 GitHub Pre-Release，包含 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种架构独立安装包。

---

## 3. Git 分支结构说明

- `main`: 当前工作分支，基于上游 `v2.1.6.2` 重构并集成 BiliTools 混流与 SD 卡双轨架构。
- `backup-sdcard-v3`: 旧版 V3 代码的完整备份分支（已推送到 `origin/backup-sdcard-v3`，永不丢失）。
- `tools/`: 本地工具库（包括 `happycola233/BiliTools`），已被 `.gitignore` 忽略，不会污染远程仓库。
