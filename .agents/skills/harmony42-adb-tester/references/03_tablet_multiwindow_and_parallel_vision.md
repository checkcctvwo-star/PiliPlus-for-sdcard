# 华为平板平行视界（App Multiplier）与多窗测试标定规范

> **知识库定位**：本文档沉淀自华为开发者联盟官方《平行视界接入指南》、《华为大屏与折叠屏 UX 设计规范》，指导 AI Agent 在 MatePad 系列平板上使用 ADB 与 UiAutomator 进行高精度控件识别、手势调度与坐标防漂移。

---

## 一、 华为平行视界（App Multiplier）核心原理

华为平行视界是系统级的应用双窗解决方案，在横屏大屏设备上以 **Activity（或 Ability）** 为单位，将同一个应用拆分为左右两栏独立呈现：

```
+-----------------------------------------------------------------------------------+
| 物理显示区域 (MatePad Pro: 2560 x 1600 @ Landscape)                                |
|  +-------------------------------------+ | +------------------------------------+ |
|  | 左栏 (Primary Pane / 0 ~ W/2)       | | | 右栏 (Secondary Pane / W/2 ~ W)    | |
|  | - 导航页 / 视频列表                 | | | - 视频播放器 / 详情页 / 评论区     | |
|  | - 独立 Activity / 独立 Task         | | | - 独立 Activity / 独立 Task        | |
|  +-------------------------------------+ | +------------------------------------+ |
|                         ^              [Divider]             ^                    |
|                         |          (防误触禁区 48px)         |                    |
|                [Window Focus: A]                     [Window Focus: B]            |
+-----------------------------------------------------------------------------------+
```

### 1. 接入标识与动态判定
- **工程清单声明**：`AndroidManifest.xml` 中配置 `<meta-data android:name="EasyGoClient" android:value="true" />`。
- **配置规则**：通过 `easygo.json` 中的 `activityPairs` 与 `defaultFullScreen` 声明双窗跳转规则。
- **状态识别**：系统侧通过 `hw-magic-windows` 标记当前处于平行视界模式。

---

## 二、 自动化测试中的三大痛点与破解对策

### 1. 痛点一：“单焦 Dump”导致节点隐身
- **现象**：当调用 `adb shell uiautomator dump` 时，系统底层默认仅导出当前拥有系统输入焦点（Input Focus）的半屏窗口，导致另一半屏幕的 UI 控件在 `window_dump.xml` 中完全消失。
- **破解协议（双窗探针协议 Dual-Window Focus Probe）**：
  1. Agent 在 XML 中未检索到目标元素时，不判定为失败；
  2. 探测目标元素预期所在方位（左栏或右栏）；
  3. 向对侧安全盲区（左侧 `(W * 0.25, H * 0.5)`，右侧 `(W * 0.75, H * 0.5)`）发送一次轻量级静默点击：
     ```bash
     adb shell input tap 640 800
     ```
  4. 延时 300ms 后重新抓取 UI 控件树，即可完整召回该侧界面。

### 2. 痛点二：中间分割条（Divider Handle）动态位移与防误触禁区
- **现象**：平行视界支持用户拖拽分栏手柄调节比例（1:1、1:2、2:1）。拖动后右栏绝对 X 坐标会发生整体平移。
- **防误触禁区规则**：
  中间分割条左右各 24px（共 48px 宽）属于系统手势拦截区。Agent 的所有 Tap 与 Swipe 动作必须约束在有效窗体内，**绝对禁止在 `[W_split - 24, W_split + 24]` 内落点**，防止误触分栏调节。

### 3. 痛点三：截图像素与 UiAutomator 逻辑坐标对齐矩阵
- **仿射缩放与宽高倒置判定**：
  若设备处于旋转状态且 `screencap` 物理分辨率 $(W_{cap}, H_{cap})$ 与 XML 根节点 `bounds` $(W_{ui}, H_{ui})$ 不一致：
  $$Scale_x = \frac{W_{cap}}{W_{ui}}, \quad Scale_y = \frac{H_{cap}}{H_{ui}}$$
- **基线固化命令**：
  在自动化用例执行前，必须强制锁定横屏与重置 DPI：
  ```bash
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation 1
  adb shell wm size reset
  adb shell wm density reset
  ```
