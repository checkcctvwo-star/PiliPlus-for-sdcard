# 鸿蒙 4.2 ADB 遥测采集与结构化缺陷工单规范

> **知识库定位**：指导 AI Agent 在 MatePad Pro 平板上进行实时日志遥测、Crash 环形缓冲区提取、四重异常指纹分类、以及全自动生成免人工口述的结构化 Markdown 缺陷工单。

---

## 一、 ADB 极速 UI 采集与手势指令集

### 1. 双通道 UI 控件树抓取流
```bash
ADB="/home/haoshuai/Android/Sdk/platform-tools/adb"

# 通道 1: exec-out 极速流式直出 (约 300ms，无设备写开销)
$ADB exec-out uiautomator dump --compressed /dev/tty

# 通道 2: 标准落盘与重试 (动画冲突退避)
$ADB shell uiautomator dump --compressed /data/local/tmp/dump.xml
$ADB shell cat /data/local/tmp/dump.xml
```

### 2. 标准交互动作指令集
| 动作 | ADB 指令 | 说明 |
| :--- | :--- | :--- |
| **精准点击** | `$ADB shell input tap <x> <y>` | 采用 Bounds 安全中心点，执行后等待 150ms |
| **精准长按** | `$ADB shell input swipe <x> <y> <x> <y> 1200` | 同坐标持续 1200ms 模拟长按 |
| **单栏滚动** | `$ADB shell input swipe <x1> <y1> <x2> <y2> 350` | 持续 350ms，禁止跨越平板中线 |
| **中文输入** | `$ADB shell cmd clipboard set text '<text>'`<br>`$ADB shell input keyevent 279` | **免安装输入法**：通过系统剪贴板注入并触发粘贴 |
| **返回键** | `$ADB shell input keyevent 4` | KEYCODE_BACK |
| **关闭软键盘** | `$ADB shell input keyevent 111` | KEYCODE_ESCAPE |

---

## 二、 四大异常指纹库与提取规则

```bash
# 1. 优先提取 Crash 专用缓冲区 (极简干净，无噪音)
$ADB logcat -b crash -d

# 2. 提取最近 200 行系统级异常
$ADB logcat -d -v threadtime -b main -b system AndroidRuntime:E DEBUG:I ActivityManager:E flutter:E *:S | tail -n 200
```

### 四大指纹识别规则：
1. **Java/Kotlin 运行时致命异常**：
   - 特征：`FATAL EXCEPTION: main`，提取 `Process:` 与 `AndroidRuntime` 异常调用栈。
2. **Native C++ 崩溃 (SIGSEGV / SIGABRT)**：
   - 特征：`DEBUG : *** ***`，提取 `signal 11 (SIGSEGV)` 及 `backtrace #00 pc`。常见于 `libmpv`/`media_kit` 跨进程空指针。
3. **Flutter Dart 崩溃**：
   - 特征：`flutter: [ERROR:flutter/runtime`，提取 Dart 空安全断言失败、RenderFlex 溢出或未捕获 Future 异常。
4. **ANR (无响应)**：
   - 特征：`ActivityManager: ANR in <package>`，通过 `dumpsys activity exit-info` 提取退出原因。

---

## 三、 标准化缺陷报告格式 (Defect Specification)

AI Agent 发现异常后必须自动输出如下标准化报告，直接交付给开发者或代码自愈智能体：

```markdown
# [AI-AUTO-DEFECT] 缺陷复现报告

## 1. 缺陷元数据
- **目标设备**: 华为 MatePad Pro (SCMR-W09), HarmonyOS 4.2.0.208 (API 31)
- **屏幕配置**: 横屏模式 (2560x1600), 平行视界双窗开启
- **被测应用**: `com.example.piliplus`
- **致命定性**: `FATAL_CRASH (Java Runtime Exception)`

## 2. 确定性复现链路
| 步骤序号 | 交互动作 | 目标元素标识 (XPath/Text/Id) | 坐标 (X, Y) | 交互后现象 |
| :---: | :---: | :--- | :---: | :--- |
| **Step 1** | Tap | `//*[@text='综合热门']` | `(640, 480)` | 右栏加载视频详情 |
| **Step 2** | Tap | `//node[@resource-id='com.example.piliplus:id/btn_download']` | `(1920, 1240)` | 弹出下载选择框 |
| **Step 3** | Tap | `//*[@text='超清 1080P']` | `(1920, 850)` | **应用瞬间闪退至桌面** |

## 3. 视觉证据链
- **现场截图**: `file:///.agents/skills/harmony42-adb-tester/artifacts/defect_latest.png`

## 4. 关键崩溃堆栈
```text
FATAL EXCEPTION: main
Process: com.example.piliplus, PID: 14208
java.lang.NullPointerException: Attempt to invoke virtual method '...' on a null object reference
    at com.example.piliplus.storage.SafStorageBridge.commitFile(SafStorageBridge.kt:88)
```

## 5. 源码定位与自愈建议
- **定位代码**: `android/app/src/main/kotlin/com/example/piliplus/storage/SafStorageBridge.kt:88`
- **根因推断**: SAF 树授权由于权限过期返回 null，未做防御性判断直接触发空指针。
- **推荐改写**: 在调用 `commitFile` 前注入 `persistedUriPermissions` 活性校验。
```
