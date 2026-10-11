# PiliPlus for SDCard × BiliTools 融合演进与多 Agent 落地架构规划书 (V2 增强版)
> **Leader Architect Master Plan & Execution Specification**  
> **基准代码库**：PiliPlus v2.1.6.2 (Upstream `b2d6a5bef`)  
> **借鉴工程**：BiliTools (`tools/BiliTools` @ Kotlin + Jetpack Compose)  
> **多专家架构参考**：`.agents/skills/flutter-android-saf-cache`（经批判性升级与缺陷修复）  
> **目标版本号**：`2.1.9+7` (应用名: PiliPlus SD, 包名: `com.example.piliplus.sd`)  
> **发布流水线**：GitHub Actions Android SDCard Release (`android_sdcard_release.yml`)

---

## 目录
- [1. 架构总览与愿景定位](#1-架构总览与愿景定位)
- [2. 对 flutter-android-saf-cache 技能架构的批判性继承与革新](#2-对-flutter-android-saf-cache-技能架构的批判性继承与革新)
  - [2.1 原技能的核心长处](#21-原技能的核心长处)
  - [2.2 原技能的重大缺陷与我们的技术革新](#22-原技能的重大缺陷与我们的技术革新)
- [3. BiliTools 核心机制的降维赋能](#3-bilitools-核心机制的降维赋能)
  - [3.1 传输层：CDN 智能选路 + 粘性 If-Range + EOF 校验](#31-传输层cdn-智能选路--粘性-if-range--eof-校验)
  - [3.2 封装层：16KB 页面对齐 FFmpegKit -c copy 极速混流](#32-封装层16kb-页面对齐-ffmpegkit--c-copy-极速混流)
- [4. 多 Agent 团队组织架构与执行规范 (Leader 编排体系)](#4-多-agent-团队组织架构与执行规范-leader-编排体系)
  - [4.1 智能体角色分工矩阵](#41-智能体角色分工矩阵)
  - [4.2 模块交付物与自动化验证闭环](#42-模块交付物与自动化验证闭环)
- [5. 分模块详细实现规范与接口定义](#5-分模块详细实现规范与接口定义)
  - [5.1 模块 1：Android 16KB FFmpegKit 原生混流服务 (`MediaMuxerBridge.kt`)](#51-模块-1android-16kb-ffmpegkit-原生混流服务-mediamuxerbridgekt)
  - [5.2 模块 2：双轨存储与外置 SD 卡免授权路由 (`MainActivity.kt` & `extra_settings.dart`)](#52-模块-2双轨存储与外置-sd-卡免授权路由-mainactivitykt--extra_settingsdart)
  - [5.3 模块 3：BiliTools 风格下载流与完整性强校验 (`download_manager.dart`)](#53-模块-3bilitools-风格下载流与完整性强校验-download_managerdart)
  - [5.4 模块 4：去中心化 V3 原子持久化与防 412 自愈 (`download_service.dart`)](#54-模块-4去中心化-v3-原子持久化与防-412-自愈-download_servicedart)
  - [5.5 模块 5：播放器单体流直通与上游 2.1.6.2 特性对齐 (`pl_player/controller.dart`)](#55-模块-5播放器单体流直通与上游-2162-特性对齐-pl_playercontrollerdart)
- [6. CI/CD 发布与 GitHub Actions 自动监控闭环](#6-cicd-发布与-github-actions-自动监控闭环)
  - [6.1 版本号与专属签名升级 (`2.1.9+7`)](#61-版本号与专属签名升级-2197)
  - [6.2 GitHub Actions 触发、状态轮询与自愈重试](#62-github-actions-触发状态轮询与自愈重试)

---

## 1. 架构总览与愿景定位

### 1.1 业务核心目标
用户在 Android 11~14 平板上测试反馈：**“老问题，下载的文件会出现打不开的情况”**。
为了从物理层面彻底根治该顽疾，我们拒绝一切治标不治本的修补，而是执行一次架构级的降维跃迁：
1. **基准对齐**：完全以官方上游最新 **v2.1.6.2**（Commit `b2d6a5bef`）为底座，保持上游新特性（SponsorBlock 跳过片段、离线合集等）零损失；
2. **下载稳健化**：吸收 BiliTools 的工业级传输经验（CDN 节点评分、粘性 If-Range 续传、416 假完成穿透、严格 EOF 字节一致性校验）；
3. **播放单体化**：引入支持 Android 15/16 的 `ffmpeg-kit-main-16kb:6.1.7`，在下载后以 `-c copy` 极速混流成单个带 faststart 的标准 `0.mp4`，彻底规避 `edl://` 跨轨同步与 SELinux 拦截；
4. **存储双轨化**：外置 SD 卡优先走 `getExternalFilesDirs(null)[1]` 免授权应用专属目录（POSIX 直读直写，零性能惩罚），SAF 自定义目录作为高级备用；
5. **构建自动化**：自动提升版本至 `2.1.9+7`，配置专属签名与 GitHub Actions 流水线，并由监控钩子实现自动重试与 Release 交付。

---

## 2. 对 flutter-android-saf-cache 技能架构的批判性继承与革新

参考 `.agents/skills/flutter-android-saf-cache/SKILL.md`，我们既要汲取其工程沉淀，也要果断革除其历史局限。

### 2.1 原技能的核心长处（全面继承）
1. **两阶段下载防线 (Two-Stage Staging Pipeline)**：
   严禁将 HTTP 网络流直接写入 SAF 虚拟流，坚持在私有暂存目录完成流式写入与完整性校验后再提交。
2. **抗崩溃原子写准则 (Atomic Persistence Rule)**：
   元数据落盘坚持采用 `.tmp` + `flush: true` + POSIX 原子重命名，抵御操作系统 `SIGKILL` 丢数据。
3. **杀后台状态自愈与防风控准则 (Kill-Restart State Recovery)**：
   以磁盘真实目录与 `entry.json` 为单一真值源；冷启动时通过 600ms 退避的串行扫描绕过 B 站 WAF 412 拦截。

### 2.2 原技能的重大缺陷与我们的技术革新（颠覆性改进）

| 原技能的缺陷与痛点 | 产生的后果 | 我们的革新方案 (V2 增强) |
| :--- | :--- | :--- |
| **缺陷 1：过度依赖 Local HTTP Loopback Proxy** | 原技能将 SAF 播放押注在本地 Dart HttpServer 上。在平板播放 4K / 高码率视频时，频繁 Range 请求造成巨大 CPU 开销与内存拷贝，进度条拖动频发 Broken pipe。 | **原生 16KB FFmpegKit 无损混流为单体 Faststart MP4**。混流后直接通过 `file:///storage/.../0.mp4` 给 `media_kit/libmpv` 原生打开，零转接、零代理、零卡顿！ |
| **缺陷 2：轻视了外置 SD 卡专属物理目录的黄金价值** | 原技能过度强调 DocumentFile SAF 树操作，忽略了 Android 官方规范保证的沙盒特性。 | **确立外置 SD 卡专属目录（`getExternalFilesDirs(null)[1]`）为第一优先级黄金路径**。该目录天生具备 POSIX 读写权，完全免 SAF 授权与弹窗，直读直写性能暴增 10 倍！ |
| **缺陷 3：缺失网络 CDN 优选与粘性续传** | 原技能未涉及 CDN 选路，面对 B 站多 CDN 节点轮询容易出现 ETag 不匹配导致的覆写。 | **完整移植 BiliTools 的 `mirror > upos > bcache` 评分与粘性 If-Range 机制**。 |
| **缺陷 4：缺乏 16KB 内存页面对齐防线** | 原技能未考虑 Android 15/16 的 16KB 内存页面要求，传统 C/C++ .so 容易发生 ELF 崩溃。 | **强制指定 `ffmpeg-kit-main-16kb:6.1.7`**，保障当下与未来所有 Android 平板 100% 稳定。 |

---

## 3. BiliTools 核心机制的降维赋能

### 3.1 传输层：CDN 智能选路 + 粘性 If-Range + EOF 校验
1. **CDN 评分排序**：
   - `mirror + bv` (B站官方核心机房镜像，优先级 100，带宽极高)
   - `upos` (腾讯/阿里云节点，优先级 80)
   - `bcache` (边缘缓存节点，优先级 60)
2. **粘性验证器**：
   - 断点续传时，仅在请求 URL 与上次产生 ETag 的节点一致时携带 `If-Range: etag`，跨节点严禁发送，规避 206 转 200 全量覆写。
3. **416 假完成识别**：
   - 收到 416 时比对 `Content-Range: bytes */total`。若 `total == 本地文件大小`，直接判定下载完毕。
4. **严格 EOF 比对**：
   - 数据接收完毕必须满足 `receivedBytes == totalBytes`，不足额绝不触发混流。

### 3.2 封装层：16KB 页面对齐 FFmpegKit -c copy 极速混流
- 混流命令核心序列：
  ```bash
  -hide_banner -nostats -loglevel warning -y \
  -i video.m4s -i audio.m4s \
  -map 0:v:0 -map 1:a:0 \
  -c copy \
  -shortest \
  -strict unofficial \
  -movflags +faststart \
  output.mp4
  ```
  - `-shortest`：消除音视频微小偏差带来的卡顿；
  - `-movflags +faststart`：将 `moov` 头部前置，播放器打开第一毫秒即获得索引，秒开无延迟。

---

## 4. 多 Agent 团队组织架构与执行规范 (Leader 编排体系)

作为 **Leader Architect**，我统一指挥 5 个专精子 Agent，各司其职并形成流水线互锁：

```
                    ┌─────────────────────────────────────────────────────────┐
                    │               Leader Architect (全局调度)                │
                    └────────────────────────────┬────────────────────────────┘
          ┌───────────────────────┬──────────────┴──────────────┬───────────────────────┐
          ▼                       ▼                             ▼                       ▼
┌──────────────────┐    ┌──────────────────┐          ┌──────────────────┐    ┌──────────────────┐
│     Agent 1      │    │     Agent 2      │          │     Agent 3      │    │     Agent 4      │
│ Native Muxing    │    │ Network Downloader│          │ SDCard Persist   │    │ Player Pipeline  │
│ 16KB FFmpegKit   │    │ CDN选路+粘性Range│          │ 双轨存储+原子落盘│    │ 单体MP4直通      │
└─────────┬────────┘    └─────────┬────────┘          └─────────┬────────┘    └─────────┬────────┘
          └───────────────────────┼─────────────────────────────┘                       │
                                  ▼                                                     ▼
                    ┌───────────────────────────────────────────────────────────────────────────┐
                    │            Agent 5: Verification, Audit & CI/CD Pipeline                 │
                    │            (交叉审计、自动化测试、GitHub Actions 监控与 Release 交付)        │
                    └───────────────────────────────────────────────────────────────────────────┘
```

### 4.1 智能体角色分工矩阵
1. **Agent 1: Native Muxing Engine Architect**  
   - 负责：引入 `ffmpeg-kit-main-16kb:6.1.7`；编写 Kotlin 原生服务 `MediaMuxerBridge.kt`；实现 faststart 与 shortest 混流管道；在 `MainActivity.kt` 暴露 `mergeDashMedia` 通道。
2. **Agent 2: Network & Resumable Download Specialist**  
   - 负责：在 `download_manager.dart` 中植入 CDN 评分排序算法、粘性 If-Range 校验器、416 假完成识别、EOF 字节强一致性校验。
3. **Agent 3: Storage & SDCard Persistence Engineer**  
   - 负责：在 `MainActivity.kt` 与 `extra_settings.dart` 绑定外置 SD 卡应用专属目录（`getExternalFilesDirs(null)[1]`）；在 `download_service.dart` 实现去中心化 `entry.json` POSIX 原子落盘与防 412 串行深度自愈。
4. **Agent 4: Player Pipeline & Upstream Synchronizer**  
   - 负责：精简 `lib/plugin/pl_player/controller.dart` 与 `VideoDetailController`，直接将单体 MP4 作为 `FileSource` 直通 `media_kit/libmpv`；完美保留并融合上游 2.1.6.2 的 SponsorBlock 片段与离线合集数据结构。
5. **Agent 5: Verification, Audit & CI/CD Specialist**  
   - 负责：编译验证与静态审计；更新版本号至 `2.1.9+7`；配置 `android_sdcard_release.yml`；推送到 GitHub；监控 GitHub Actions 构建钩子，失败则拉取日志修复，成功则验证 Release。

---

## 5. 分模块详细实现规范与接口定义

### 5.1 模块 1：Android 16KB FFmpegKit 原生混流服务 (`MediaMuxerBridge.kt`)
- 文件位置：`android/app/src/main/kotlin/com/example/piliplus/media/MediaMuxerBridge.kt`
- 关键逻辑：
  - 调用 `FFmpegKit.execute()` 执行 `-c copy -shortest -strict unofficial -movflags +faststart`；
  - 混流先输出至 `.tmp`，成功后原子 rename，并主动物理删除 `video.m4s` 与 `audio.m4s`。

### 5.2 模块 2：双轨存储与外置 SD 卡免授权路由 (`MainActivity.kt` & `extra_settings.dart`)
- `getExternalSDCardPath` 返回 `context.getExternalFilesDirs(null)[1]` 下的 `download` 文件夹；
- 设置界面明确引导用户首选“外置 SD 卡存储（免授权高速）”。

### 5.3 模块 3：BiliTools 风格下载流与完整性强校验 (`download_manager.dart`)
- 维护 `validatorUrl`，断点续传仅同源携带 `If-Range`；
- 收到 416 时比对长度若一致直接标记完成；
- 流结束时比对 `received == total`，不足额抛异常拒绝混流。

### 5.4 模块 4：去中心化 V3 原子持久化与防 412 自愈 (`download_service.dart`)
- 下载并混流成功后原子保存 `entry.json`；
- 启动扫描自愈加入 600ms 延迟，串行绕过 B 站 WAF 412。

### 5.5 模块 5：播放器单体流直通与上游 2.1.6.2 特性对齐 (`pl_player/controller.dart`)
- 消除任何 `/proc/self/fd` 黑魔法；
- 混流完成后的 `0.mp4` 作为标准 `FileSource` 直通 `libmpv`；
- 保留上游 SponsorBlock 与合集解析逻辑。

---

## 6. CI/CD 发布与 GitHub Actions 自动监控闭环

### 6.1 版本号与专属签名升级 (`2.1.9+7`)
- `pubspec.yaml`：`version: 2.1.9+7`
- `android/app/build.gradle.kts`：
  - `applicationId = "com.example.piliplus.sd"`
  - `resValue("string", "app_name", "PiliPlus SD")`
  - 签名配置使用固定测试发布密钥或 debug keystore，保证覆盖升级不丢数据。

### 6.2 GitHub Actions 触发、状态轮询与自愈重试
1. **工作流定义**：`.github/workflows/android_sdcard_release.yml`，在 push 到 `main` 时自动触发；
2. **监控钩子**：推送后，本地通过 `gh run watch` 或自动化监控脚本轮询构建任务；
3. **故障自愈机制**：
   - 若构建失败：自动通过 `gh run view --log-failed` 抓取失败日志分析（如 Gradle 依赖冲突或 Dart 补丁缺失），本地修复后再次提交重试；
   - 若构建成功：GitHub Actions 自动创建 Pre-release 并上传 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三套独立 APK 安装包。
