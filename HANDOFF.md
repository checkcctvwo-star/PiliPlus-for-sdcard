# PiliPlus for SDCard - 智能体交接与测试验证全景指南 (Handoff V5)

> **文档状态**: 生产级测试与交接规约 (Ready for Agent Verification)  
> **更新时间**: 2026-10-18  
> **目标版本**: PiliPlus SD `v2.1.9+8` (Commit `b4b8316ff`)  
> **应用信息**: 包名 `com.example.piliplus.sd` / 应用名 `PiliPlus SD` (固定 Debug 签名，支持直接覆盖升级)  
> **基准上游**: PiliPlus v2.1.6.2 (Commit `b2d6a5bef`)  
> **测试对象**: 后续接手测试/验证的 AI 智能体 (Verification Agent / Tester) 及开发者

---

## 目录
- [一、 执行摘要与发布资产 (Executive Summary & Release Assets)](#一-执行摘要与发布资产-executive-summary--release-assets)
- [二、 核心问题剖析与技术改造清单 (What Changed & What Was Done)](#二-核心问题剖析与技术改造清单-what-changed--what-was-done)
  - [2.1 彻底解决“重启几次后离线缓存视频完全消失”](#21-彻底解决重启几次后离线缓存视频完全消失)
  - [2.2 彻底解决“下载未转码、残留音画分离 M4S 切片”](#22-彻底解决下载未转码残留音画分离-m4s-切片)
  - [2.3 彻底解决“设置中选择 SD 卡存储失效/置灰”与 SAF 计算崩溃](#23-彻底解决设置中选择-sd-卡存储失效置灰与-saf-计算崩溃)
  - [2.4 彻底实现“两阶段暂存提交”与“APP 卸载重装 100% 恢复”](#24-彻底实现两阶段暂存提交与app-卸载重装-100-恢复)
  - [2.5 播放器本地媒体自适应感知与在线回放本地化](#25-播放器本地媒体自适应感知与在线回放本地化)
- [三、 代码文件改动清单 (Code Inventory)](#三-代码文件改动清单-code-inventory)
- [四、 测试智能体操作指南 (Step-by-Step Testing & Verification Guide)](#四-测试智能体操作指南-step-by-step-testing--verification-guide)
  - [4.1 前置准备与 ADB 环境初始化](#41-前置准备与-adb-环境初始化)
  - [4.2 测试用例 1：常规下载与标准 MP4 混流验证](#42-测试用例-1常规下载与标准-mp4-混流验证)
  - [4.3 测试用例 2：存储目录三轨切换验证 (本机 / 外置 SD 卡 / SAF)](#43-测试用例-2存储目录三轨切换验证-本机--外置-sd-卡--saf)
  - [4.4 测试用例 3：冷启动与强杀进程持久化验证 (Persistence Test)](#44-测试用例-3冷启动与强杀进程持久化验证-persistence-test)
  - [4.5 测试用例 4：终极测试——卸载重装自愈还原验证 (Uninstall Recovery)](#45-测试用例-4终极测试卸载重装自愈还原验证-uninstall-recovery)
  - [4.6 测试用例 5：底层播放器 (libmpv) 播放与 Seek 验证](#46-测试用例-5底层播放器-libmpv-播放与-seek-验证)
  - [4.7 测试用例 6：自动化端到端测试套件执行](#47-测试用例-6自动化端到端测试套件执行)
- [五、 测试验收矩阵与签署检查单 (Verification Checklist)](#五-测试验收矩阵与签署检查单-verification-checklist)
- [六、 故障排查与应急回退手册 (Troubleshooting & Rollback)](#六-故障排查与应急回退手册-troubleshooting--rollback)

---

## 一、 执行摘要与发布资产 (Executive Summary & Release Assets)

针对用户在物理平板（Android 11~14 / 鸿蒙 4.2）上反馈的**“下载文件打不开/黑屏”、“未混流转码成标准 MP4”、“重启后离线缓存消失”、“SD卡目录选择失效/置灰”**等顽疾，经过多专家智能体协同重构，已彻底完成架构跃迁，并通过自动化 CI/CD 流水线构建出最新安装包。

### 📦 GitHub Release 专属发布信息
- **Release 页面**: [PiliPlus SD – v2.1.9-sd-20261011-0625](https://github.com/checkcctvwo-star/PiliPlus-for-sdcard/releases/tag/v2.1.9-sd-20261011-0625)
- **直接下载资产 (Direct APK Assets)**:
  - 📱 **ARM64-v8a (绝大多数物理平板首选)**: [piliplus_v2.1.9-sd-20261011-0625_arm64-v8a.apk](https://github.com/checkcctvwo-star/PiliPlus-for-sdcard/releases/download/v2.1.9-sd-20261011-0625/piliplus_v2.1.9-sd-20261011-0625_arm64-v8a.apk)
  - 📱 **ARMv7a (旧款 32 位设备)**: [piliplus_v2.1.9-sd-20261011-0625_armeabi-v7a.apk](https://github.com/checkcctvwo-star/PiliPlus-for-sdcard/releases/download/v2.1.9-sd-20261011-0625/piliplus_v2.1.9-sd-20261011-0625_armeabi-v7a.apk)
  - 💻 **x86_64 (电脑安卓模拟器)**: [piliplus_v2.1.9-sd-20261011-0625_x86_64.apk](https://github.com/checkcctvwo-star/PiliPlus-for-sdcard/releases/download/v2.1.9-sd-20261011-0625/piliplus_v2.1.9-sd-20261011-0625_x86_64.apk)
- **签名保证**: 使用一致的 Debug 证书签名，版本号 `2.1.9+8`，**支持直接覆盖安装升级，覆盖更新不丢失既有下载数据**。

---

## 二、 核心问题剖析与技术改造清单 (What Changed & What Was Done)

```mermaid
flowchart TD
    subgraph S1 [阶段一: 沙盒极速下载与混流 (POSIX)]
        A[开始下载] --> B[本地缓存暂存区 download_staging]
        B --> C[下载 video.m4s + audio.m4s + cover + danmaku]
        C --> D[自适应两阶段 16KB FFmpegKit 混流]
        D -->|Phase 1: -c copy| E{混流成功?}
        E -->|否/FLAC/杜比| F[Phase 2: 自动降级 AAC 192k 转码]
        E -->|是| G[生成标准 0.mp4, 自动物理删除 .m4s 切片]
        F --> G
        G --> H[原子写入 entry.json]
    end

    subgraph S2 [阶段二: 外部存储原子提交]
        H --> I{目标存储路径类型}
        I -->|Type 0/1: 本机或外置SD卡沙盒| J[POSIX 原子转移至 SD卡应用沙盒]
        I -->|Type 2: 自定义 SAF 目录| K[SafStorageBridge 流式原子覆写 DocumentFile]
        J --> L[外部目标目录形成去中心化自包含闭环]
        K --> L
    end

    subgraph S3 [阶段三: 杀后台/重启/卸载重装自愈]
        L --> M[APP强杀 / 平板重启 / APP卸载重装]
        M --> N[启动或重选目录]
        N --> O[UniversalCacheRecoveryEngine 通用自愈扫描引擎]
        O -->|Tier 1: 容错 entry.json| P[瞬间恢复 100% 离线缓存视频列表]
        O -->|Tier 2: 遗留切片修复| Q[自动 FFmpeg 修复混流为 0.mp4]
        O -->|Tier 3: 逆向离线合成| R[解析文件夹名还原 avid/cid 补齐元数据]
    end
```

### 2.1 彻底解决“重启几次后离线缓存视频完全消失”
- **根因定位**:
  - 原 `lib/main.dart` 的 `_initDownPath()` 仅判断了 `if (type == 1)`，当用户选择了自定义 SAF 目录（`type == 2`）时，启动时直接落入 `else` 分支，将 `downloadPath` 强制覆写回应用默认内部存储 `defDownloadPath`。APP 重启后去扫描空的默认内部目录，导致已下载视频完全不可见。
  - `Directory(contentUri).existsSync()` 在对 `content://` URI 执行时永远返回 `false`。
  - `BiliDownloadEntryInfo.fromJson` 包含过刚硬的类型断言（`as int`），任何字段缺失都会引发运行时 `TypeError` 崩溃导致扫描中断。
- **技术改造**:
  - 重构 `lib/main.dart` 中的 `_initDownPath()`，对 `type == 2` 保持持久化的 `content://` URI，对 `type == 1`（外置 SD 卡）增加防系统挂载延迟重试。
  - 引入 `BiliDownloadEntryInfo.fromLenientJson()`，提供数值、字符串、布尔全安全转换兜底。

### 2.2 彻底解决“下载未转码、残留音画分离 M4S 切片”
- **根因定位**:
  - B 站部分高规格音频流（如 Hi-Res FLAC、Dolby Atmos/E-AC3）在 MP4 封装时被原生 `-c copy` 拒绝；原代码未做自适应重编码降级，导致混流静默失败而保留原始 `.m4s`。
  - B 站 DASH 流的 DTS 时间戳存在微小的非单调递增抖动，引发 FFmpeg 执行中止。
  - 缺乏并发互斥锁，多视频同时混流时 CPU 与 I/O 拥塞。
- **技术改造**:
  - 重写 `android/app/src/main/kotlin/com/example/piliplus/media/MediaMuxerBridge.kt`：
    1. 加入 `muxMutex` 协程互斥锁，确保混流串行稳健执行；
    2. 加入 `-fflags +genpts+discardcorrupt -avoid_negative_ts make_zero` 解决 DTS 乱序报错；
    3. 实现**自适应两阶段混流**：Phase 1 尝试 `-c copy`，若失败自动降级至 Phase 2 重编码为标准 AAC 192k (`-c:v copy -c:a aac -b:a 192k -ar 48000`)，确保 100% 合成标准单个 `0.mp4`；
    4. 混流成功后物理清理源端 `.m4s` 切片，并调用 `FFmpegKitConfig.clearSessions()` 回收内存。

### 2.3 彻底解决“设置中选择 SD 卡存储失效/置灰”与 SAF 计算崩溃
- **根因定位**:
  - `lib/pages/setting/models/extra_settings.dart` 通过 `snapshot.data!.length > 1` 判定是否有 SD 卡，在华为等平板上该系统 API 仅返回 1 条记录，导致 SD 卡选项直接置灰（`onPressed: null`）。
  - 在计算目录大小时，遇到 `content://` 目录直接调用 Dart 原生 `Directory.list()` 抛出异常。
- **技术改造**:
  - 解除 SD 卡选项的置灰限制，常驻可点击；点击时直接调用原生底层 `getExternalSDCardPath` 多卷挂载扫描。
  - 目录大小计算迁移至原生底层 `DownloadManager.calculateDirSize()`，自适应支持 POSIX 路径和 `content://` 虚拟树。

### 2.4 彻底实现“两阶段暂存提交”与“APP 卸载重装 100% 恢复”
- **根因定位**:
  - Android 系统的 `DocumentFile.renameTo()` 在 **exFAT / FAT32** 外置 SD 卡上存在系统底层 Bug，经常失败。
  - 历史版本将下载状态绑定在私有状态机中，一旦卸载重装，即使文件在 SD 卡上也无法找回。
- **技术改造**:
  - **两阶段暂存提交 (Two-Stage Pipeline)**：
    - `Stage 1 (暂存区)`: 下载与混流都在内部沙盒 `appSupportDirPath/download_staging/...` 极速完成（100% POSIX 兼容，零延迟无碎片）；
    - `Stage 2 (原子提交)`: 混流为 `0.mp4` 后，通过 `SafStorageBridge.commitFileToSaf` 以流式验证方式原子同步至用户指定的外部目录（SD 卡或 SAF 目录）。
  - **去中心化自愈扫描引擎 (`UniversalCacheRecoveryEngine`)**:
    - 每个视频文件夹完全自包含（`0.mp4` + `entry.json` + `cover.jpg` + `danmaku.pb`）。
    - 哪怕**彻底卸载 APP 再重装**，只要在“设置 - 下载目录”中重新选中该文件夹，应用会自动深度递归扫描全量视频，并 **100% 还原展示在离线缓存列表中**！
    - 若扫描时发现历史遗留未转码的 `.m4s` 切片，引擎会自动调度后台 FFmpeg 混流将其修复为标准 MP4。

### 2.5 播放器本地媒体自适应感知与在线回放本地化
- **根因定位**:
  - `media_kit` (libmpv) 无法识别 `content://` 虚拟协议，传入会导致黑屏或闪退。
- **技术改造**:
  - `FileSource` 严格探测磁盘上物理存在的 `0.mp4`，优先以单轨 MP4 秒启播放；
  - 极特殊情况下无 MP4 时，安全回退至双轨 DASH 播放，保证绝不黑屏；
  - 原生层新增 `openSafFd`，通过 `pfd.detachFd()` 构造 `fdclose://$fd` 零拷贝管道交付给 `libmpv`；
  - 在线视频详情页引入本地已下载感知：浏览在线视频时若本地已存在该清晰度文件，自动优先播放本地文件，节省流量并秒开。

---

## 三、 代码文件改动清单 (Code Inventory)

| 文件路径 | 模块归属 | 核心改动内容 |
|---|---|---|
| `android/app/src/main/kotlin/com/example/piliplus/media/MediaMuxerBridge.kt` | Android 原生 | 增加 `muxMutex` 互斥锁、DTS 纠偏参数、自适应 Phase 1 copy / Phase 2 AAC 降级、m4s 物理清理、session 缓存释放 |
| `android/app/src/main/kotlin/com/example/piliplus/storage/SafStorageBridge.kt` | Android 原生 (新增) | 实现 SAF DocumentFile 流式原子提交、递归扫描 `scanEntriesFromSaf`、目录大小计算 `calculateSafSize`、零拷贝 FD `openSafFd` |
| `android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt` | Android 原生 | 注册 MethodChannel 桥接 (`mergeDashMedia`, `commitStagingEntry`, `scanSafEntries`, `calculateDirSize`, `getExternalSDCardPath`, `openSafFd`) |
| `lib/models_new/download/bili_download_entry_info.dart` | Flutter 模型 | 增加 `fromLenientJson` 宽容类型解析工厂方法，防止启动解析中断 |
| `lib/services/download/universal_cache_recovery_engine.dart` | Flutter 业务 (新增) | 通用三级自愈扫描引擎，支持 POSIX / SAF 深度递归还原、遗留切片自动混流与离线逆向合成 |
| `lib/services/download/download_manager.dart` | Flutter 业务 | 增加 MethodChannel 静态桥接方法，包含原子提交、SAF 扫描与目录大小计算 |
| `lib/services/download/download_service.dart` | Flutter 业务 | 接入两阶段 staging 暂存目录，完成时调用原子提交；接入 `UniversalCacheRecoveryEngine` 重写 `_readDownloadList` |
| `lib/main.dart` | Flutter 入口 | 修复 `_initDownPath` 对 `type == 2` (SAF) 的持久化保持，修复 `defDownloadPath` 只读 getter 错误，引入 `defaultAndroidPath` |
| `lib/pages/setting/models/extra_settings.dart` | Flutter 设置 | 解除 SD 卡选项置灰限制，统一采用 `DownloadManager.calculateDirSize` 计算缓存大小 |
| `lib/plugin/pl_player/models/data_source.dart` | Flutter 播放器 | `FileSource` 增加磁盘 `0.mp4` 真实物理存在校验与自适应单流/双流降级 |
| `lib/pages/video/controller.dart` | Flutter 视频页 | 增加已下载本地文件的智能感知重定向 |
| `pubspec.yaml` | 项目配置 | 版本号升级为 `2.1.9+8` |
| `test/services/download/download_and_mux_test.dart` | 测试套件 (新增) | `FileSource` 自适应双轨及 MP4 判定单元测试 |
| `test/services/download/storage_system_stress_test.dart` | 测试套件 (新增) | 670 行系统级存储仿真、边界压力与自愈恢复端到端测试套件 |
| `.agents/skills/flutter-android-saf-cache/SKILL.md` | 项目记忆 (升级) | 升级为 V2.0，写入 exFAT 规约、自适应 FFmpeg 规范与自愈架构铁律 |
| `docs/PROJECT_ARCHITECTURE_BACKGROUND_MEMORY.md` | 项目记忆 (新增) | 完整的项目背景、历史演进、技术深度拆解与避坑记忆文档 |

---

## 四、 测试智能体操作指南 (Step-by-Step Testing & Verification Guide)

接手验证的智能体（或测试人员）请按照以下标准作业程序 (SOP) 进行测试：

### 4.1 前置准备与 ADB 环境初始化

```bash
# 1. 确认 ADB 连接状态 (确保平板通过 USB 或无线 ADB 连接，状态为 device)
adb devices -l

# 2. 检查安装包是否存在 (如需本地下载安装)
curl -L -O https://github.com/checkcctvwo-star/PiliPlus-for-sdcard/releases/download/v2.1.9-sd-20261011-0625/piliplus_v2.1.9-sd-20261011-0625_arm64-v8a.apk

# 3. 覆盖安装应用 (保留既有数据)
adb install -r piliplus_v2.1.9-sd-20261011-0625_arm64-v8a.apk

# 4. 授予必要的文件管理权限
adb shell pm grant com.example.piliplus.sd android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.example.piliplus.sd android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.example.piliplus.sd MANAGE_EXTERNAL_STORAGE allow
```

### 4.2 测试用例 1：常规下载与标准 MP4 混流验证
- **目的**: 验证下载完成后是否自动合并为单个标准 `0.mp4`，且 `.m4s` 切片被清理。
- **操作步骤**:
  1. 打开应用，进入任意高清视频（如 1080P 或 4K 视频）；
  2. 点击离线缓存，选择清晰度并开始下载；
  3. 观察下载过程与完成提示；
  4. 通过 ADB 查看目标目录的文件结构：
     ```bash
     adb shell "run-as com.example.piliplus.sd ls -la files/download/*/*"
     # 或在外置 SD 卡沙盒目录下查看:
     adb shell "ls -la /storage/*/Android/data/com.example.piliplus.sd/files/download/*/*"
     ```
- **预期结果**:
  - 目录下存在 `0.mp4`、`entry.json`、`cover.jpg`、`danmaku.pb`；
  - 严禁存在残留的 `video.m4s` 或 `audio.m4s`；
  - `entry.json` 中的 `media_type` 字段应为 `1`。

### 4.3 测试用例 2：存储目录三轨切换验证 (本机 / 外置 SD 卡 / SAF)
- **目的**: 验证“其他设置 - 下载目录”中三种模式切换是否有效。
- **操作步骤**:
  1. 进入应用【我的】->【设置】->【其他设置】->【选择下载目录】；
  2. **验证选项 1 (本机存储)**：点击切换，验证路径恢复为默认私有沙盒；
  3. **验证选项 2 (SD 卡存储)**：点击该选项（确认不再置灰且可点），应用自动探测外置 SD 卡沙盒路径，点击确认；
  4. **验证选项 3 (自定义 SAF 目录)**：点击后调出系统文件选择器，在 SD 卡上自建或选择一个外部文件夹（如 `PiliPlus`），点击【使用此文件夹】并授权。
- **预期结果**:
  - 所有选项切换均弹出成功 Toast；
  - 若原有视频超过 500MB，弹出迁移确认框且进度条平稳完成迁移；
  - 新下载的文件准确落入用户最新选定的目录中。

### 4.4 测试用例 3：冷启动与强杀进程持久化验证 (Persistence Test)
- **目的**: 验证用户反馈的“重启几次后离线缓存视频消失”问题是否彻底解决。
- **操作步骤**:
  1. 确保离线缓存列表中至少有 2~3 个已完成的视频；
  2. 使用 ADB 模拟系统杀后台 / 强杀进程：
     ```bash
     adb shell am force-stop com.example.piliplus.sd
     ```
  3. 重新启动应用：
     ```bash
     adb shell am start -n com.example.piliplus.sd/com.example.piliplus.MainActivity
     ```
  4. 进入【离线缓存】页面，检查视频列表；
  5. 重复强杀与启动操作 3 次（包括重启平板物理设备）。
- **预期结果**:
  - 离线缓存列表中的所有视频条目 100% 完整展现；
  - 封面、标题、清晰度标签、时长完整显示；
  - 点击即可秒开播放。

### 4.5 测试用例 4：终极测试——卸载重装自愈还原验证 (Uninstall Recovery)
- **目的**: 验证“APP 彻底卸载重装后，重新选定该目录能找回所有视频”。
- **操作步骤**:
  1. 在【自定义 SAF 目录】模式下下载 2 个视频；
  2. 记录所选的外部目录路径（例如 SD 卡根目录下的 `/PiliPlus` 文件夹）；
  3. **彻底卸载 APP**：
     ```bash
     adb uninstall com.example.piliplus.sd
     ```
  4. 重新安装全新 APK：
     ```bash
     adb install piliplus_v2.1.9-sd-20261011-0625_arm64-v8a.apk
     ```
  5. 打开全新安装的应用，此时离线缓存列表为空；
  6. 进入【其他设置】->【选择下载目录】->【自定义 SAF 目录】，重新选中步骤 2 记录的那个外部文件夹；
  7. 返回【离线缓存】页面。
- **预期结果**:
  - `UniversalCacheRecoveryEngine` 自动触发后台扫描；
  - 之前下载的所有视频被 100% 还原展示在列表中，元数据与封面恢复，点击即可正常流畅播放！

### 4.6 测试用例 5：底层播放器 (libmpv) 播放与 Seek 验证
- **目的**: 验证底层 `libmpv` 打开离线 MP4 的兼容性。
- **操作步骤**:
  1. 断开平板的 Wi-Fi 与移动网络（开启飞行模式）；
  2. 打开已下载的离线视频；
  3. 频繁进行快进、快退、拖动进度条（Seek）；
  4. 切换清晰度（若有）或开启倍速播放；
  5. 测试切换后台悬浮窗（画中画 PiP）与锁屏后台播放。
- **预期结果**:
  - 画面瞬间起播，无黑屏，无无声现象；
  - 音画绝对同步（音画时间戳对齐）；
  - 拖动进度条后画面秒级响应，无崩溃、无 Broken pipe 崩溃异常。

### 4.7 测试用例 6：自动化端到端测试套件执行
- **目的**: 验证 Dart 层的逻辑完备性与极端压力边界。
- **操作步骤**:
  ```bash
  # 在终端中执行单元测试与系统级压力测试
  flutter test test/services/download/download_and_mux_test.dart
  flutter test test/services/download/storage_system_stress_test.dart
  ```
- **预期结果**:
  - 全部测试用例通过（PASS），覆盖 Scoped Storage 边界、exFAT 原子写、杀后台自愈与并发锁竞争。

---

## 五、 测试验收矩阵与签署检查单 (Verification Checklist)

测试智能体在执行完上述验证后，请对照下表填写验收结论：

| 序号 | 验证模块 | 测试项与验收标准 | 验证方法 | 验收结论 (Pass/Fail) |
|---|---|---|---|---|
| **1** | **混流验证** | 下载完成后生成单体 `0.mp4`，源端 `.m4s` 物理清除 | ADB 检查文件结构 | `[  ]` |
| **2** | **格式兼容** | 包含 FLAC / 杜比等音频流的视频能自动降级 AAC 成功合并 | 观察 Logcat 混流日志 | `[  ]` |
| **3** | **SD卡设置** | 设置页面“SD卡存储”常驻可点，正确探测外置卷路径 | UI 点击测试 | `[  ]` |
| **4** | **冷启动持久化** | 连续 3 次强杀进程 / 设备重启后，离线列表不消失 | `am force-stop` 压力测试 | `[  ]` |
| **5** | **卸载自愈恢复** | 彻底卸载重装 APP 后，选定原目录能 100% 找回全部视频 | 卸载重装实测 | `[  ]` |
| **6** | **离线断网播放** | 飞行模式下离线视频秒启播放，音画同步，Seek 顺滑 | 纯离线回放 | `[  ]` |
| **7** | **在线本地感知** | 浏览在线视频页时优先使用本地已缓存的 MP4 播放 | 检查网络占用与加载速度 | `[  ]` |
| **8** | **自动化测试** | `storage_system_stress_test.dart` 670 行端到端测试全绿 | `flutter test` 执行 | `[  ]` |

---

## 六、 故障排查与应急回退手册 (Troubleshooting & Rollback)

### 6.1 常见故障现象与排查手段

#### 现象 A：ADB 连接提示 `device offline` 或找不到设备
- **排查**: 运行 `adb kill-server && adb start-server`。拔插 USB 数据线，检查平板屏幕是否弹出“允许 USB 调试”授权框并勾选“始终允许”。

#### 现象 B：混流阶段 Logcat 提示 `ReturnCode` 异常
- **排查**: 查看 Logcat 过滤标签 `MediaMuxerBridge`：
  ```bash
  adb logcat -s MediaMuxerBridge:V
  ```
  检查 Phase 1 失败原因。若 Phase 2 (AAC) 亦失败，检查设备磁盘剩余空间是否充足（混流需预留约 1.5 倍视频大小的临时空间）。

#### 现象 C：SAF 授权目录在重装后无法选择
- **排查**: 部分 Android 厂商系统在 DocumentUI 中默认隐藏 SD 卡根目录。指导用户在系统文件管理器右上角菜单中勾选“显示内部存储设备”或“显示 SD 卡”。

### 6.2 应急代码回退检查点 (Rollback Checkpoints)
- **最新稳定提交**: `b4b8316ff` (`test(download): add comprehensive system-level storage stress and recovery tests`)
- **前一版发布提交**: `6d716c934` (`fix: resolve defaultAndroidPath fallback in _initDownPath`)
- **历史备份分支**: `origin/backup-sdcard-v3`（包含早期所有改动的离线冷备，永不丢失）。
