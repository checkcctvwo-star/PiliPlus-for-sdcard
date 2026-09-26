# SD卡下载重构 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 Flutter 混合开发架构下，基于 Aria (Java) + MethodChannel 实现高鲁棒性的 SD 卡下载与息屏保活机制，并搭建 GitHub Actions 输出 Debug 共存包。

**架构：** Flutter 层 UI 提供“优先下载到 SD 卡”选项；原生端 Aria 接管底层下载与 MD5 校验，使用 Foreground Service 防止系统杀后台。构建系统通过 applicationIdSuffix 实现测试包并存。

**技术栈：** Flutter (Dart), Android (Kotlin/Java), Aria, GitHub Actions

**规格：** docs/superpowers/specs/2026-09-13-sdcard-download-design.md

## 全局约束
- 目标平台兼容：Android 8.0+ / HarmonyOS 3+
- 原生代码规范：优先使用 Kotlin (如果已有 MainActivity 是 Java 则延用 Java)，注意跨线程 MethodChannel.Result 的主线程回调。
- 依赖项：引入 `com.arialyy.aria:core:3.8.16`。

---

### 任务 1：DevOps CI/CD 配置与测试包共存

**文件：**
- 修改：`android/app/build.gradle`
- 创建：`.github/workflows/android_debug_build.yml`

- [ ] **步骤 1：配置 Debug 共存包名**
修改 `android/app/build.gradle` 中的 `buildTypes` -> `debug` 块，添加 `applicationIdSuffix ".debug"` 和 `versionNameSuffix "-debug"`。

- [ ] **步骤 2：创建 CI/CD Workflow**
在 `.github/workflows/android_debug_build.yml` 中编写 GitHub Actions 流程，包含：checkout 源码、setup-java 17、setup flutter、执行 `flutter build apk --debug` 并 upload-artifact。

- [ ] **步骤 3：Commit**
```bash
git add android/app/build.gradle .github/workflows/android_debug_build.yml
git commit -m "ci: add github actions for debug apk and setup app id suffix"
```

### 任务 2：原生 Android 下载引擎与前台服务

**文件：**
- 修改：`android/app/src/main/AndroidManifest.xml`
- 修改：`android/app/build.gradle` (添加 Aria 依赖)
- 创建/修改：`android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt` (或 .java)

- [ ] **步骤 1：声明前台服务权限**
在 AndroidManifest.xml 声明 `android.permission.FOREGROUND_SERVICE`，以及如果是 Android 14 需要 `android.permission.FOREGROUND_SERVICE_DATA_SYNC`。

- [ ] **步骤 2：添加 Aria 依赖**
在 `android/app/build.gradle` dependencies 中添加 `implementation 'com.arialyy.aria:core:3.8.16'` 及 compiler 依赖。

- [ ] **步骤 3：实现 MethodChannel 通信层**
在 MainActivity 中注册 `com.piliplus/download` MethodChannel。实现 `startDownload(url, path)`、`pauseDownload()`、`resumeAll()` 方法并转交 Aria 执行。

- [ ] **步骤 4：Commit**
```bash
git add android/
git commit -m "feat(android): integrate Aria download engine and method channel"
```

### 任务 3：Flutter 侧 DownloadService 对接

**文件：**
- 修改：`lib/services/download/download_manager.dart`

- [ ] **步骤 1：封装 MethodChannel 调用**
在 `lib/services/download/download_manager.dart` (或对应下载逻辑文件) 中，初始化 MethodChannel 并暴露 `startDownload(String url, String savePath)`、`pauseAll()` 等 Dart 方法。

- [ ] **步骤 2：应用启动时触发静默恢复**
在初始化方法（如 `init()`）中添加发送 `resumeAll()` 指令到底层，解决强杀导致的恢复问题。

- [ ] **步骤 3：Commit**
```bash
git add lib/services/download/
git commit -m "feat(flutter): bridge aria method channel for downloads"
```

### 任务 4：设置界面 UI 与 SD 卡检测

**文件：**
- 修改：`lib/pages/setting/view.dart` (或 `extra_settings.dart`)
- 修改：`android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt` (新增获取 SD 卡路径 channel)

- [ ] **步骤 1：原生端提供外置路径 API**
在 MainActivity 的 MethodChannel 中增加 `getExternalSDCardPath()`，通过 `Context.getExternalFilesDirs(null)` 提取外置 SD 卡的绝对路径（返回 String 或 null）。

- [ ] **步骤 2：设置 UI 新增开关**
在设置页面增加 Switch (优先下载到外置 SD 卡)。点击切换前，调用原生方法验证 SD 卡路径是否非空。若非空则切换成功并保存至本地 KV 存储，若空则弹窗提示无 SD 卡。

- [ ] **步骤 3：Commit**
```bash
git add lib/pages/setting/ android/
git commit -m "feat(ui): add sd card storage priority toggle in settings"
```
