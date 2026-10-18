# 源码自愈闭环工程手册 (Code Self-Healing Playbook)

> **知识库定位**：指导 AI Agent 在获取到自动化测试缺陷报告后，如何精确映射到工程本地源码（Flutter Dart / Android Kotlin）、实施最小侵入式防御性补丁、执行增量构建并回归重放验证。

---

## 一、 代码自愈闭环状态机

```
[1. 捕获崩溃报告] 
       │
       ▼
[2. 源码符号映射] ──► 正则提取 Dart (lib/...) 或 Kotlin (android/app/...) 文件与行号
       │
       ▼
[3. 上下文与防御补丁] ──► 注入空安全守卫 / mounted 检查 / SAF 树权限检查
       │
       ▼
[4. 增量热更新 / 重构建] ──► Flutter HotRestart 或 assembleDebug + adb install
       │
       ▼
[5. 原动作链回归重放] ──► 重放 Step 1~3 手势
       │
       ├─► 验证通过 ──► 提交自愈 Git Commit 并结单 (Closed)
       └─► 再次失败 ──► 触发熔断保护 (最多重试 2 次，禁止越界重构)
```

---

## 二、 堆栈到源码的精准映射器 (Source Mapper)

### 1. Flutter Dart 堆栈解析规则
- **特征正则**：`#\d+\s+[\w\.<>]+\s+\(package:[^/]+/([^:]+):(\d+):(\d+)\)`
- **映射逻辑**：提取第一组为 `lib/$1`，第二组为行号。
  - 示例：`#0 VideoDetailPageState._onDownload (package:piliplus/pages/video/video_detail.dart:214:35)`
  - 真实源码路径：`lib/pages/video/video_detail.dart` 第 214 行。

### 2. Android Kotlin / Java 堆栈解析规则
- **特征正则**：`at\s+([a-zA-Z0-9_.]+)\.([a-zA-Z0-9_]+)\(([a-zA-Z0-9_]+\.kt):(\d+)\)`
- **映射逻辑**：反查 `android/app/src/main/kotlin/**/<filename>` 并定位行号。
  - 示例：`at com.example.piliplus.storage.SafStorageBridge.commitFile(SafStorageBridge.kt:88)`
  - 真实源码路径：`android/app/src/main/kotlin/com/example/piliplus/storage/SafStorageBridge.kt` 第 88 行。

---

## 三、 四大经典崩溃模式与防御性自愈策略库

### 模式 A：Flutter 强行解包 `!` 导致的 Null Check 崩溃
- **典型堆栈**：`Null check operator used on a null value`
- **自愈改写规范**：
  ```dart
  // 修复前:
  final downloadUrl = currentVideo.mediaInfo!.urls.first!;

  // 修复后 (防御性守卫):
  final mediaUrls = currentVideo.mediaInfo?.urls;
  if (mediaUrls == null || mediaUrls.isEmpty || mediaUrls.first == null) {
    LogUtils.w("VideoDetail", "媒体下载地址为空，终止分发");
    ToastUtils.show("当前清晰度暂无可用播放流");
    return;
  }
  final downloadUrl = mediaUrls.first!;
  ```

### 模式 B：跨异步帧 `BuildContext` 丢失引发的 UI 异常
- **典型堆栈**：`Looking up a deactivated widget's ancestor is unsafe`
- **自愈改写规范**：
  在所有异步 `await` 之后，强制注入 `mounted` 守卫：
  ```dart
  await SafStorageBridge.prepareDownloadStaging(taskId);
  if (!mounted) return; // 自动注入的自愈守卫
  setState(() {
    isStagingReady = true;
  });
  ```

### 模式 C：Android SAF 树权限失效异常
- **典型堆栈**：`java.lang.SecurityException: Permission Denial: opening provider ... requires ...`
- **自愈改写规范 (Kotlin)**：
  ```kotlin
  val hasPermission = context.contentResolver.persistedUriPermissions.any { 
      it.uri == treeUri && it.isWritePermission 
  }
  if (!hasPermission) {
      Log.e("SafStorageBridge", "目标 SAF 权限已失效: $treeUri")
      result.error("SAF_PERMISSION_EXPIRED", "外置存储权限已失效，请重新授权", null)
      return
  }
  ```

### 模式 D：平板横屏分栏下的 RenderFlex 布局溢出
- **典型堆栈**：`A RenderFlex overflowed by 48.0 pixels on the bottom.`
- **自愈改写规范**：
  将窄屏下溢出的非滚动 `Column` 包裹为 `SingleChildScrollView`，或用 `Expanded` 包裹弹性子项。

---

## 四、 熔断机制与安全底线 (Circuit Breaker)

为了防止 AI Agent 陷入盲目改写代码引发连锁反应，必须严格遵守以下红线：
1. **重试上限**：针对同一 Bug 最多尝试 **2 次修复**。
2. **代码修改配额**：单次自愈修改不得超过 **30 行**，禁止修改全局配置文件或重构架构。
3. **熔断回滚**：若第 2 次重放依然失败，强制执行 `git checkout -- .` 恢复代码基线，并生成汇总日志提示人工接管。
