---
name: harmony42-adb-tester
description: 鸿蒙 4.2 系统平板专用的 AI Agent 自动化控制、全功能黑盒/白盒测试、知识库避坑与代码自愈闭环技能包。专为华为 MatePad Pro 系列（HarmonyOS 4.2 / AOSP 12 API 31/32 双框架、2.5K/2.8K 屏幕、平行视界双窗）设计。深度覆盖：(1) 鸿蒙4.2底层文件写入六重限制与外置物理SD卡 (exFAT/FAT32/SAF) 架构防线；(2) 基于 ADB 协议的高性能流式 UI 遍历、平行视界双窗焦点探针与安全手势流；(3) 免人工口头表达的结构化缺陷报告自动生成（调用栈/录屏截图/复现链路）；(4) 自动化源码定位、防御性补丁生成、增量重载与重放验证自愈闭环 (Self-Healing Loop)。
version: "1.0.0"
metadata:
  models: ["gemini-3.8-flash", "gemini-3.1-pro"]
  compatible_agents: ["antigravity", "claude-code", "cursor", "windsurf"]
  target_os: "HarmonyOS 4.2 (Android 12 / AOSP API 31/32)"
  supported_devices: ["Huawei MatePad Pro (SCMR-W09)", "Huawei MatePad 11", "HarmonyOS 4.2 Tablets"]
  tags: ["harmonyos", "harmonyos-4.2", "adb", "testing", "self-healing", "saf", "sdcard", "tablet", "matepad"]
---

# HarmonyOS 4.2 Tablet ADB Test Automation & Self-Healing Skill

本技能包为 AI 智能体（如 Gemini 3.8 Flash / 3.1 Pro）提供在 **华为鸿蒙 4.2 平板（如 MatePad Pro，基于 Android 12 AOSP 兼容层）** 上执行 **端到端设备控制、功能性探索测试、大文件存储规约审计、免人工表述的结构化缺陷报告生成、以及源码自愈重写 (Self-Healing Loop)** 的完整操作规程。

## 📚 华为官方技术知识库索引 (Knowledge Base Index)
在执行高精度排障或代码自愈前，智能体可查阅以下深度规范文献：
1. **[01_底层存储架构与大文件 I/O 知识库](file:///home/haoshuai/Linux-AI-project/piliplus-for-sdcard/.agents/skills/harmony42-adb-tester/references/01_huawei_harmonyos_storage_architecture.md)**：六重限制漏斗、Core File Kit、FUSE Passthrough、FAT32 vs exFAT 物理格式、SAF vs POSIX 沙盒分流。
2. **[02_后台任务与功耗调度治理规范](file:///home/haoshuai/Linux-AI-project/piliplus-for-sdcard/.agents/skills/harmony42-adb-tester/references/02_huawei_powergenie_and_background_tasks.md)**：华为 Background Tasks Kit 接入规范、PowerGenie 冻结规避、Foreground Service `dataSync` 绑定、Wakelock 治理。
3. **[03_平行视界与多窗测试标定规范](file:///home/haoshuai/Linux-AI-project/piliplus-for-sdcard/.agents/skills/harmony42-adb-tester/references/03_tablet_multiwindow_and_parallel_vision.md)**：华为 App Multiplier (`easygo.json`, `hw-magic-windows`)、双窗焦点探针协议、分割手柄 48px 禁区、仿射坐标矩阵。
4. **[04_ADB 遥测采集与结构化缺陷工单规范](file:///home/haoshuai/Linux-AI-project/piliplus-for-sdcard/.agents/skills/harmony42-adb-tester/references/04_adb_telemetry_and_defect_schema.md)**：流式 UI Dump、四大异常指纹库（Fatal/Native/Dart/ANR）、标准化机器/人类双消费 Markdown 工单模板。
5. **[05_源码自愈闭环工程手册](file:///home/haoshuai/Linux-AI-project/piliplus-for-sdcard/.agents/skills/harmony42-adb-tester/references/05_code_self_healing_playbook.md)**：堆栈到本地源码符号映射、四大防御性补丁范式、增量热更新与重放验证、2次熔断保护机制。
- **辅助工具脚本**：`scripts/device_probe.sh`（一键固化横屏、清除动画、重置 DPI 与挂载探查）。

---

## 一、 鸿蒙 4.2 底层存储机制与避坑铁律 (Storage Knowledge Base)

### 1. 【文件写入大小限制的真实源头：六重限制漏斗】
在鸿蒙 4.2 中，Linux 内核与系统层本身**不存在全局统一的人为写入大小上限**。所谓“大文件写入失败或被限制”，是由以下六重底层机制引发：

1. **文件系统物理硬顶**：
   - **FAT32**：单文件物理上限严格为 **$4\text{GB} - 1\text{ 字节}$ ($4,294,967,295$ B)**。超出立即报 `EFBIG (File too large, errno 27)`。
   - **exFAT**（当前平板实测格式）：单文件上限达 **16EB**，现实中完全无限制。
   - **内部存储 (F2FS/ext4)**：单文件上限 3.94TB~16TB，无 4GB 限制。
2. **C 库与内核指针寻址**：
   - 64 位进程 (`arm64-v8a`) 原生支持 64 位 `off_t`，寻址空间达 9.22EB。
   - 32 位老旧动态库若未配置 `-D_FILE_OFFSET_BITS=64`，会在 **2GB** 处截断抛出 `EOVERFLOW`。
3. **堆内存与流式模型**：
   - 严禁将大文件一次性读入字节数组（如 `response.body().bytes()` 或 Dart `Uint8List`）。
   - App 进程堆上限常规仅 192MB~256MB（开启 `largeHeap` 也仅 512MB），非流式写入必触发 `OutOfMemoryError` 或被 `lmkd` 发送 `SIGKILL 9` 强杀。必须采用 **64KB~128KB 缓冲区的 Streaming 管道**。
4. **Binder IPC 1MB 事务墙**：
   - Binder 共享缓冲区上限仅 **1MB**。严禁通过 Binder/AIDL 直接传递分块字节数组（会抛 `TransactionTooLargeException`）。
   - SAF 写入大文件依靠传递 **`ParcelFileDescriptor` (PFD)** 直连内核 VFS 管道，彻底绕过 Binder 1MB 限制。
5. **用户态 FUSE 延迟与超时**：
   - Android 12 内部存储享有内核级 **FUSE Passthrough**；而外置 SD 卡和 SAF 虚拟树必须跨用户态 MediaProvider 守护进程。低速 SD 卡高频写入会导致 I/O 拥塞，触发线程 D 状态与 ANR。
6. **鸿蒙 PowerGenie / iAware 后台防偷跑机制**：
   - 鸿蒙系统在三方应用退到后台、熄屏约 3~5 分钟后，启动 **Cgroup Freezer 挂起进程、切断网络并强制回收高耗电应用**。
   - **解法**：长时间后台大文件下载必须挂载带有效进度通知的 **`Foreground Service` (foregroundServiceType="dataSync")**。

### 2. 【浏览器下载公共目录稳如磐石的原因】
- **执行主体解耦**：浏览器将下载委托给系统特权服务 `com.android.providers.downloads` (UID: system/shared)，即使划掉浏览器卡片，下载仍在内核级独立运行。
- **系统级白名单**：系统下载服务享有 PowerGenie 永久豁免权与合法常驻 `PARTIAL_WAKE_LOCK`。
- **内部 UFS + fallocate 预分配**：公共 `Download/` 位于板载 UFS 闪存，原生支持 `fallocate()` 一次性分配物理块，杜绝磁盘碎片与元数据频繁刷盘瓶颈。

### 3. 【外置物理 SD 卡存储分流决策】
- **路径 A：免权限高速沙盒 (`Context.getExternalFilesDirs(null)[1]`)**：
  - 路径格式：`/storage/<UUID>/Android/data/<package_name>/files/`
  - **优势**：支持标准 POSIX API（`dart:io File` / `fopen`），原生极速直写，无需任何运行时权限或弹窗。
  - **代价**：**应用卸载时随之被系统彻底清除**。
- **路径 B：持久保留 SAF 虚拟树 (`ACTION_OPEN_DOCUMENT_TREE`)**：
  - 经由系统 Picker 授权 `content://` URI，数据持久保留。
  - **铁律**：必须采用**两阶段流水线（Staging in Cache -> Atomic Commit to SAF）**，严禁将网络流直接暴露给 SAF 流。

---

## 二、 鸿蒙 4.2 平板 ADB 智能交互与自动化测试规范

### 1. 测试前环境基线固化协议 (Pre-Test Routine)
在执行任何测试用例前，必须运行以下命令抹平动态干扰：
```bash
ADB="/home/haoshuai/Android/Sdk/platform-tools/adb"

# 1. 锁定屏幕方向为横屏 (Orientation = 1)，关闭自动旋转
$ADB shell settings put system accelerometer_rotation 0
$ADB shell settings put system user_rotation 1

# 2. 重置屏幕基准尺寸与 DPI
$ADB shell wm size reset
$ADB shell wm density reset

# 3. 关闭系统动画（避免 UIAutomator 抓取时的 device busy 超时）
$ADB shell settings put global window_animation_scale 0.0
$ADB shell settings put global transition_animation_scale 0.0
$ADB shell settings put global animator_duration_scale 0.0
```

### 2. 平行视界（App Multiplier）双窗探针协议 (Dual-Window Focus Probe)
鸿蒙平板在平行视界下运行双 Activity。`uiautomator dump` 默认可能仅抓取当前聚焦窗口：
- **探针机制**：若在 Dump 出的 XML 中未发现目标元素：
  1. 计算屏幕对侧安全盲区坐标：左屏盲点 `(W * 0.25, H * 0.5)`，右屏盲点 `(W * 0.75, H * 0.5)`；
  2. 发送轻量点击切换系统焦点：`$ADB shell input tap <Px> <Py>`；
  3. 等待 300ms 后重新抓取 UI 树。
- **防误触禁区**：中间分栏拖动手柄周围 `[W_split - 24, W_split + 24]` 为系统手势区，严禁在此区间落点。

### 3. UI 控件树抽取与极速解析
```bash
# 极速流式 Dump (约 300ms，无需落盘)
$ADB exec-out uiautomator dump --compressed /dev/tty

# 备选稳定落盘 Dump
$ADB shell uiautomator dump --compressed /data/local/tmp/uidump.xml
$ADB shell cat /data/local/tmp/uidump.xml
```

### 4. 标准手势模拟指令表
| 交互动作 | ADB 底层指令 | 规范与避坑要点 |
| :--- | :--- | :--- |
| **精准点击** | `$ADB shell input tap <Cx> <Cy>` | 使用 Bounds 安全中心点，执行后等待 150ms |
| **精准长按** | `$ADB shell input swipe <Cx> <Cy> <Cx> <Cy> 1200` | 同坐标滑动模拟长按，推荐 1000~1500ms |
| **单栏滚动** | `$ADB shell input swipe <x1> <y1> <x2> <y2> 350` | 耗时 350ms 带惯性；禁止跨越平板中线 |
| **中文文本输入** | `$ADB shell cmd clipboard set text '<text>'`<br>`$ADB shell input keyevent 279` | **免安装输入法**：通过系统剪贴板注入并触发粘贴 |
| **物理返回** | `$ADB shell input keyevent 4` | `KEYCODE_BACK`，逐级返回或收起键盘/弹窗 |

---

## 三、 免人工口头表达的结构化缺陷报告规范 (Defect Specification)

当 Agent 在测试过程中检测到异常、闪退或白屏时，立即执行以下捕获：
```bash
# 1. 抓取 Crash 专用环形缓冲区
$ADB logcat -b crash -d

# 2. 抓取系统运行时 Fatal 错误
$ADB logcat -d -v threadtime -b main -b system AndroidRuntime:E DEBUG:I ActivityManager:E flutter:E *:S | tail -n 200

# 3. 截取现场屏幕
$ADB exec-out screencap -p > .agents/skills/harmony42-adb-tester/artifacts/defect_latest.png
```

Agent 必须将问题自动生成为以下格式的结构化报告，**彻底替代人工口述**：
```markdown
### [AI-AUTO-DEFECT] 缺陷复现报告
- **触发模块**: <页面名 / 功能组件>
- **设备环境**: 华为 MatePad Pro (SCMR-W09), HarmonyOS 4.2.0.208 (API 31)
- **复现路径**:
  1. Action: Tap [坐标 (x, y)] -> 进入某页面
  2. Action: Input Text "..." -> 触发某操作
  3. Action: Tap [确认按钮] -> 发生闪退
- **现场截图**: `file:///.agents/skills/harmony42-adb-tester/artifacts/defect_latest.png`
- **致命异常日志**:
  ```text
  <粘贴抓取到的 Fatal Exception / Dart Exception / ANR 堆栈>
  ```
- **关联代码定位**: `<filepath>:<line>`
- **根因推断**: <AI 结合源码的推断>
```

---

## 四、 源码自愈闭环流程 (Self-Healing Loop)

```
[1. 捕获崩溃日志]
       │
       ▼
[2. 源码符号映射] ───► 解析堆栈: Dart (lib/...) 或 Kotlin (android/app/...)
       │
       ▼
[3. 上下文与防御补丁] ──► 注入空安全守卫 / mounted 检查 / SAF 树重授权捕获
       │
       ▼
[4. 增量热更新/重构建] ──► flutter run 热重载 或 flutter build apk + adb install
       │
       ▼
[5. 原动作链回归重放] ───► 重放 Step 1~3 坐标手势
       │
       ├─► 验证通过 ──► 提交自愈 Git Commit 并结单
       └─► 再次失败 ──► 触发熔断保护 (最多重试 2 次，单次 Diff <= 30 行)
```

### 常用防御性自愈补丁范式：
1. **Flutter 空安全解包崩掉**：
   将 `val!` 替换为 `val?` 链式调用与非空保护判断。
2. **异步 UI 回调 context 丢失**：
   在所有 `await` 操作后强制插入 `if (!mounted) return;`。
3. **Android SAF 权限静默过期**：
   在原生 Kotlin `MethodChannel` 回调中，检查 `persistedUriPermissions`，若失效返回特定错误码引导重新授权。
4. **平板横屏多窗 RenderFlex 溢出**：
   将窄屏下溢出的 `Column` 包裹为 `SingleChildScrollView`。

---

## 五、 快速验证命令集

- **检查平板连接**：`/home/haoshuai/Android/Sdk/platform-tools/adb devices`
- **启动测试目标应用**：`/home/haoshuai/Android/Sdk/platform-tools/adb shell monkey -p com.example.piliplus -c android.intent.category.LAUNCHER 1`
- **导出当前界面控件**：`/home/haoshuai/Android/Sdk/platform-tools/adb exec-out uiautomator dump --compressed /dev/tty`
- **捕获屏幕**：`/home/haoshuai/Android/Sdk/platform-tools/adb exec-out screencap -p > /tmp/tablet_screen.png`
