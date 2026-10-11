---
name: flutter-android-saf-cache
description: 专用于 Flutter 与 Android 原生深度融合的专家级工程技能包。深度覆盖 Android 11~15 Scoped Storage (SAF / DocumentFile / 外部 SD 卡扩展存储)、断点续传两阶段下载流水线、底层流媒体播放器 (media_kit/libmpv) 本地代理桥接、Aria 原生服务状态对齐、文件完整性原子写入 (Atomic Write) 与抗崩溃杀后台自愈 (Kill-Restart Recovery)。特别适配 Gemini 3.8 Flash 与 3.1 Pro 多智能体协作。
version: "1.0.0"
metadata:
  models: ["gemini-3.8-flash", "gemini-3.1-pro"]
  compatible_agents: ["antigravity", "claude-code", "cursor", "windsurf"]
  tags: ["flutter", "android", "saf", "scoped-storage", "download", "cache", "sdcard"]
---

# Flutter & Android SAF / Cache Architecture Expert Skill

本技能包专为在高难度 Android 跨端开发场景（尤其是外部物理 SD 卡存储、大文件分片断点续传、底层流媒体播放桥接、杀后台高可靠自愈）中指导 AI 智能体（如 Gemini 3.8 Flash 与 Gemini 3.1 Pro）进行精准架构设计与代码实现。

---

## 一、 架构铁律 (Non-Negotiable Engineering Rules)

### 1. 【存储分流决策铁律】(Storage Classification Rule)
- ❌ **严禁假设 POSIX 路径对任意外部 SD 卡生效**：在 Android 11+ (API 30~15) 上，除 `Context.getExternalFilesDirs(null)` 返回的沙盒路径外，外部 SD 卡根目录与其他路径**没有任何直接可写的 POSIX 文件路径**。严禁使用 `dart:io` `File('/storage/XXXX-XXXX/...')` 强行写入。
- ✅ **严格按照需求分流**：
  1. **免权限高速沙盒**：若只需利用 SD 卡扩展容量，随应用卸载删除，使用 `getExternalFilesDirs(null)[1]`（直接操作 POSIX 路径，支持标准 I/O 与秒级重命名）。
  2. **用户自选与持久保留**：若要求用户自选 SD 卡任意目录且卸载不丢数据，必须使用 `Intent.ACTION_OPEN_DOCUMENT_TREE` 获取持久权限（`takePersistableUriPermission`），并通过 `DocumentFile` 或 `saf_stream` 进行虚拟 URI 树操作。

### 2. 【两阶段下载提交防线】(Two-Stage Staging Pipeline)
- ❌ **绝对禁止将 HTTP 网络流分块直接写入 SAF `content://` 流**：高频跨进程 Binder IPC 调用会导致系统 I/O 线程池锁死，极易在弱网或网络断开时引发不可恢复的挂起。
- ✅ **标准二阶段流水线**：
  - **阶段 1 (Staging)**：以 POSIX 高速 I/O 下载到应用私有沙盒临时目录（如 `app_flutter/cache/*.part`），支持 HTTP Range 断点续传与 MD5/SHA256 完整性校验。
  - **阶段 2 (Commit)**：校验通过后，在目标 SAF 目录下创建临时占位文件（如 `.<filename>.tmp`），通过 `ContentResolver.openOutputStream` 管道一次性写入，强刷磁盘（`flush`），随后显式删除旧同名文件并调用 `renameTo` 原子重命名，最后清理本地沙盒暂存文件。

### 3. 【播放器 I/O 跨协议桥接准则】(Media Player Bridging Protocol)
- ❌ **严禁向 `media_kit` / `libmpv` 直接传入 `content://` URI**：底层 C/C++ 多媒体内核无法识别 Android 虚拟 ContentProvider 协议，会导致播放器静默退出或报 `Failed to open file`。
- ✅ **优先方案：Local HTTP Loopback Proxy**：
  - 启动本地环回代理服务（`127.0.0.1:<port>`），将媒体 URL 封装为 `http://127.0.0.1:<port>/stream?uri=<encoded_saf_uri>`。
  - 代理服务监听并解析 HTTP `Range: bytes=start-end`，通过原生 `openFileDescriptor("r")` 获取文件描述符后定位 Seek 位置，响应 `HTTP 206 Partial Content`。
  - **异常容忍**：必须捕获客户端 Seek 操作导致的 `SocketException (Broken pipe / Connection reset)`，静默丢弃连接，绝不可向外抛出引发应用崩溃。
- ✅ **备选方案：`fdclose://$fd` 协议**：原生层通过 `pfd.detachFd()` 获取文件描述符整数，构造 `Media("fdclose://$fd")` 交由 `libmpv` 消费并托管释放。

### 4. 【抗崩溃原子写入准则】(Atomic Persistence Rule)
- ❌ **严禁原地直接覆盖写入元数据**（如直接 `file.writeAsString(json)`）。在应用被系统 `SIGKILL` 强杀或异常断电时，将产生 0 字节文件或残缺 JSON。
- ✅ **三步原子写范式**：
  ```dart
  final tmpFile = File('${targetFile.path}.tmp');
  await tmpFile.writeAsString(jsonContent, flush: true); // 强制刷入硬件闪存
  tmpFile.renameSync(targetFile.path); // POSIX 挂载点内原子替换
  ```

### 5. 【杀后台状态自愈与防风控准则】(Kill-Restart State Recovery)
- ❌ **严禁依赖纯内存状态机作为单点真值**。
- ✅ **磁盘真值优先 (Decentralized File-System Truth)**：每个视频任务保持独立的元数据文件（如 `entry.json`）。启动时扫描磁盘实际存在的分片与元数据。
- ✅ **HTTP 416 幂等判别**：断点重试发起 `Range: bytes=$received-` 时，若收到 HTTP 416，且 `received >= total`，说明文件已完整下载，直接标记完成；若 `received < total`，判定分片损坏，清除重下。
- ✅ **API 412 串行节流回退**：批量恢复下载任务向服务端拉取元信息时，强制串行化执行并在任务之间插入 `400ms~600ms` 节流延时，抵御防爬与 WAF 拦截。

### 6. 【原生通道隔离与委托法则】(Native Channel Quarantine & Delegate Rule)
- ❌ **严禁在 UI Widget、ViewModel 或 Notifier 中散落实例化 `MethodChannel`**。
- ✅ **通道物理隔离**：所有原生交互统一收敛至 `lib/services/native/` 或专用 Bridge 服务。
- ✅ **委托法则**：`MainActivity.kt` 等生命周期宿主类代码必须精简，仅做入参解构与事件转发，具体 SAF 遍历、Aria 任务拉取、FD 转换逻辑委托给纯 Kotlin 业务类，确保可脱机运行单元测试。

---

## 二、 多智能体协作分工指南 (Multi-Agent Division of Labor)

在 Antigravity 调遣多个子智能体协同开发时，按照以下架构切分：

1. **主架构编排智能体 (Lead Orchestrator - 推荐 Gemini 3.1 Pro)**：
   - 负责任务规划、跨语言契约推导、审查 MethodChannel 命名与字段格式、协调合并分支。
2. **Flutter UI 与下载状态流智能体 (UI Specialist - 推荐 Gemini 3.8 Flash)**：
   - 负责下载管理页面、任务进度条更新、批处理按钮互斥锁（`isBatchProcessing`）、网络状态切换 Toast。
   - 重点检查：避免在频繁进度更新时触发整屏重绘，采用精确局部监听（如 `ValueListenableBuilder` 或按任务 ID 隔离）。
3. **Android 原生底层与存储智能体 (Native SAF Specialist - 推荐 Gemini 3.1 Pro / 3.8 Flash)**：
   - 负责 `android/app/src/main/kotlin/` 下的 `MainActivity.kt`、SAF DocumentFile 增删改查、Aria 任务状态同步、Local Proxy Server 端口健康检查。
4. **测试与质量审计智能体 (Auditor Specialist - 推荐 Gemini 3.8 Flash)**：
   - 验证跨语言字段命名一致性（Dart vs Kotlin）、检查是否存在未关闭的文件流/描述符、测试网络断开重试与进程被杀状态恢复。

---

## 三、 快速参考代码模板

### 1. SAF 两阶段提交 Kotlin 核心逻辑
```kotlin
fun commitFileToSaf(context: Context, srcFilePath: String, treeUri: Uri, targetFileName: String, mimeType: String): Boolean {
    val srcFile = File(srcFilePath)
    if (!srcFile.exists()) return false

    val treeDoc = DocumentFile.fromTreeUri(context, treeUri) ?: return false
    val tmpFileName = ".$targetFileName.tmp"
    
    // 1. 创建或复用临时占位文件
    val tmpDoc = treeDoc.findFile(tmpFileName) ?: treeDoc.createFile(mimeType, tmpFileName) ?: return false
    
    // 2. 管道流传输与刷盘
    context.contentResolver.openOutputStream(tmpDoc.uri)?.use { outStream ->
        FileInputStream(srcFile).use { inStream ->
            inStream.copyTo(outStream)
            outStream.flush()
        }
    } ?: return false
    
    // 3. 删除旧目标文件并重命名
    treeDoc.findFile(targetFileName)?.delete()
    return tmpDoc.renameTo(targetFileName)
}
```

### 2. Local Proxy Server 容错流代理响应 Dart 核心逻辑
```dart
Future<void> handleStreamRequest(HttpRequest request, String safUri) async {
  try {
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final (start, end, totalSize) = parseRange(rangeHeader, safUri);
    
    request.response.statusCode = rangeHeader != null ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalSize');
    request.response.headers.contentType = ContentType('video', 'mp4');

    final stream = openSafByteStream(safUri, start, end);
    await request.response.addStream(stream);
    await request.response.close();
  } on SocketException catch (_) {
    // 捕获客户端拖动进度条造成的 Broken pipe，静默释放
  } catch (e, stack) {
    request.response.statusCode = HttpStatus.internalServerError;
    await request.response.close();
  }
}
```
