---
name: flutter-android-saf-cache
description: 专用于 Flutter 与 Android 原生深度融合的专家级工程技能包。深度覆盖 Android 11~15 Scoped Storage (SAF / DocumentFile / 外部 SD 卡扩展存储)、断点续传两阶段下载流水线、自适应 16KB FFmpegKit 音画混流 (DTS平滑/AAC降级)、底层流媒体播放器 (media_kit/libmpv) 本地代理与 fdclose 桥接、自包含目录去中心化持久化 (Self-Contained Storage)、exFAT/FAT32 兼容、文件完整性原子写入 (Atomic Write) 与抗崩溃杀后台自愈 (Kill-Restart Recovery)。特别适配 Gemini 3.8 Flash 与 3.1 Pro 多智能体协作。
version: "2.0.0"
metadata:
  models: ["gemini-3.8-flash", "gemini-3.1-pro"]
  compatible_agents: ["antigravity", "claude-code", "cursor", "windsurf"]
  tags: ["flutter", "android", "saf", "scoped-storage", "download", "cache", "sdcard", "ffmpegkit", "recovery"]
---

# Flutter & Android SAF / Cache Architecture Expert Skill (v2.0)

本技能包专为在高难度 Android 跨端开发场景（尤其是外部物理 SD 卡存储、大文件分片断点续传、音视频切片混流、底层流媒体播放桥接、杀后台高可靠自愈、APP 卸载重装恢复）中指导 AI 智能体（如 Gemini 3.8 Flash 与 Gemini 3.1 Pro）进行精准架构设计与代码实现。

---

## 一、 架构铁律 (Non-Negotiable Engineering Rules)

### 1. 【存储分流决策铁律】(Storage Classification Rule)
- ❌ **严禁假设 POSIX 路径对任意外部 SD 卡生效**：在 Android 11+ (API 30~35) 上，除 `Context.getExternalFilesDirs(null)` 返回的沙盒路径外，外部 SD 卡根目录与其他路径**没有任何直接可写的 POSIX 文件路径**。严禁使用 `dart:io` `File('/storage/XXXX-XXXX/...')` 强行写入。
- ✅ **严格按照需求分流**：
  1. **免权限高速沙盒 (Type 1)**：若只需利用 SD 卡扩展容量，随应用卸载删除，使用 `getExternalFilesDirs(null)[1]`（直接操作 POSIX 路径，支持标准 I/O 与秒级重命名）。
  2. **用户自选与持久保留 (Type 2)**：若要求用户自选 SD 卡任意目录且卸载不丢数据，必须使用 `Intent.ACTION_OPEN_DOCUMENT_TREE` 获取持久权限（`takePersistableUriPermission`），并通过 `DocumentFile` 流式写入。
  3. **本机私有沙盒 (Type 0)**：应用默认内部存储 `context.filesDir`，适合机身自带存储充足的用户。

### 2. 【两阶段下载提交与 exFAT 容错防线】(Two-Stage Staging & Commit Pipeline)
- ❌ **绝对禁止将 HTTP 网络流分块直接写入 SAF `content://` 流**：高频跨进程 Binder IPC 调用会导致系统 I/O 线程池锁死，极易在弱网或网络断开时引发不可恢复的挂起。
- ❌ **严禁依赖 `DocumentFile.renameTo()` 作为唯一原子提交手段**：在外置 SD 卡的 exFAT / FAT32 文件系统上，Android 系统的 DocumentProvider 经常在 `renameTo()` 时抛出 `Operation not permitted` 或静默返回 `false`。
- ✅ **标准二阶段流水线**：
  - **阶段 1 (Staging 暂存区)**：网络下载（视频/音频/封面/弹幕）与 FFmpeg 混流必须全部在应用私有沙盒临时目录（`appSupportDirPath/download_staging/...`）中完成。具备 100% 原生 POSIX 性能，零 Binder IPC 开销。
  - **阶段 2 (Commit 原子提交)**：混流验证生成 `0.mp4` 且元数据写入后，再触发提交。对于 SAF 模式，采用流式覆盖管道（写入 `.filename.tmp` -> 验证文件大小 -> 覆盖目标文件），安全清理本地暂存区。

### 3. 【自适应 16KB FFmpegKit 音画混流准则】(Adaptive FFmpeg Muxing & DTS Rule)
- ❌ **严禁使用单一 `-c copy` 应对所有 B 站音频流**：B 站 Hi-Res 无损（FLAC）、杜比全景声（Dolby Atmos/E-AC3）等音频编码在标准 MP4 容器中无法直接流复制，会导致混流抛错，残留 `.m4s` 切片。
- ❌ **严禁在未平滑 DTS 时间戳的情况下进行混流**：B 站分片常存在非单调递增 DTS，必须加入 `-fflags +genpts+discardcorrupt -avoid_negative_ts make_zero` 参数，防止源端抖动导致报错中断。
- ✅ **四层混流防御体系**：
  1. **互斥锁保护 (`muxMutex`)**：防止多任务并发混流竞争 I/O 导致平板内核死锁。
  2. **Phase 1 (极速流复制)**：`-c copy -shortest -strict unofficial -movflags +faststart`。
  3. **Phase 2 (自动 AAC 转码降级)**：Phase 1 失败时自动无缝降级为 `-c:v copy -c:a aac -b:a 192k -ar 48000`，确保 100% 生成标准单个 `0.mp4`。
  4. **原生堆回收**：混流完成后调用 `FFmpegKitConfig.clearSessions()` 防止内存泄漏，并自动安全删除源端临时 `.m4s` 切片。
  5. **16KB 页面对齐**：必须使用 `io.github.jamaismagic.ffmpeg:ffmpeg-kit-main-16kb:6.1.7` 适配 Android 15/16。

### 4. 【自包含目录与通用自愈扫描引擎准则】(Self-Contained Storage & Recovery Engine)
- ❌ **严禁将视频状态单点绑定在 APP 私有数据库中**：若元数据仅存放在本地 SQLite/Hive，APP 卸载重装后外部存储上的视频将彻底失联。
- ✅ **自包含去中心化规约 (Self-Contained Directory)**：
  - 每个视频目录必须独立包含：`0.mp4` (标准媒体)、`entry.json` (完整元数据)、`cover.jpg` (封面)、`danmaku.pb` (弹幕)。
- ✅ **通用扫描自愈三级阶梯 (`UniversalCacheRecoveryEngine`)**：
  - **Tier 1 (容错元数据恢复)**：扫描 `entry.json`，使用 `fromLenientJson` 宽容解析，校验 `0.mp4` 字节数，瞬间恢复下载列表。
  - **Tier 2 (遗留切片修复)**：若存在未混流的 `video.m4s` 与 `audio.m4s`，后台自动调度 FFmpeg 修复混流为 `0.mp4` 并补全 `entry.json`。
  - **Tier 3 (逆向离线合成)**：即便丢失 `entry.json`，只要存在 `0.mp4`，通过文件夹目录名逆向解析 `avid` / `cid`，自动构造合成条目。
  - **卸载重装找回**：用户卸载并重装应用后，只要在设置中重新选定该下载文件夹，引擎递归扫描即可 100% 恢复所有历史离线视频！

### 5. 【播放器 I/O 跨协议桥接与本地感知准则】(Media Player Bridging Protocol)
- ❌ **严禁向 `media_kit` / `libmpv` 直接传入 `content://` URI**：底层 C/C++ 多媒体内核无法识别 Android 虚拟 ContentProvider 协议，会导致播放器静默退出或报 `Failed to open file`。
- ✅ **零拷贝 `fdclose://$fd` 协议**：原生层通过 `pfd.detachFd()` 获取只读文件描述符整数，构造 `Media("fdclose://$fd")` 交由 `libmpv` 消费并托管自动关闭。
- ✅ **播放器单体流自适应感知 (`FileSource`)**：
  - 严格校验磁盘真实存在的 `dir/0.mp4` 或 `dir/<tag>/0.mp4`。只要存在标准 MP4，无论入参状态如何，均自动以单流模式秒启播放。
  - 若仅存在双切片（混流失败极特殊情况），安全回退至双流 DASH 播放，保证绝不黑屏。
- ✅ **在线页面智能本地回放**：用户浏览在线视频时，若本地存在对应清晰度的已下载视频，自动无缝重定向为本地离线播放。

### 6. 【代码陷阱与避坑记忆】(Pitfalls & Memory Checklist)
- ⚠️ **`defDownloadPath` 只读 Getter 陷阱**：`lib/utils/path_utils.dart` 中 `String get defDownloadPath => ...` 为 Getter，绝不可对其赋值！回退路径应声明局部变量（如 `final defaultAndroidPath = ...`）。
- ⚠️ **`Directory(uri).existsSync()` 陷阱**：Dart 原生文件系统 API 无法识别 `content://`，对 SAF URI 检查必然返回 `false`。必须通过原生通道判断。
- ⚠️ **HTTP 416 幂等判别**：断点重试发起 `Range: bytes=$received-` 时，若收到 HTTP 416，且 `received >= total`，说明文件已完整下载，直接标记完成；若 `received < total`，判定分片损坏，清除重下。
- ⚠️ **API 412 串行节流回退**：批量恢复下载任务向服务端拉取元信息时，强制串行化执行并在任务之间插入 `400ms~600ms` 节流延时，抵御防爬与 WAF 拦截。

---

## 二、 多智能体协作与测试验证规约 (Multi-Agent Verification Protocol)

在多智能体流水线中，测试与验证智能体（Verification Agent）必须按照以下标定步骤执行：

1. **环境准备与状态确认**：
   - 使用 ADB 连接物理设备：`adb devices -l`。
   - 确认当前安装版本为 `com.example.piliplus.sd`。
2. **下载与混流测试**：
   - 触发 1080P/高码率视频下载，观察日志输出 `Phase 1 (-c copy)` 或 `Phase 2 (AAC transcode)`。
   - 确认目标目录下生成单个标准的 `0.mp4`，原始 `.m4s` 被清理。
3. **冷启动与重启持久化测试**：
   - 通过 `adb shell am force-stop com.example.piliplus.sd` 强杀应用。
   - 重启应用，检查离线缓存列表中视频条目是否完整呈现、封面与时长是否正常。
4. **卸载重装恢复测试 (Uninstall Recovery)**：
   - 记录外部存储目录路径。
   - 卸载应用：`adb uninstall com.example.piliplus.sd`。
   - 重新安装最新构建的 APK，进入设置将下载路径重新指向该外部目录。
   - 验证 `UniversalCacheRecoveryEngine` 是否触发并 100% 还原视频列表。
5. **单元测试与压力测试执行**：
   - 运行：`flutter test test/services/download/download_and_mux_test.dart`
   - 运行：`flutter test test/services/download/storage_system_stress_test.dart`
