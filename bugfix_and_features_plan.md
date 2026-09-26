# 需求分析与实施计划 (PiliPlus SD卡下载补全与新功能开发)

## 1. 痛点与需求拆解
1. **Bug修复：SD卡下载目录选择无效**
   - **现状**：即使开启了“优先下载到外置SD卡”，实际文件仍落在 `android/data` (私有目录)。
   - **目标**：将单纯的 Toggle 开关改为 **“下载目录挑选器”**。提供三项：① 本机存储 (默认) ② SD卡存储 (检测可用后出现) ③ 自定义目录 (通过原生 SAF 挑选文件夹)。
2. **新功能 1：离线缓存界面批量控制**
   - **目标**：在缓存界面增加“全部暂停 / 全部继续”按钮，根据当前任务状态自动切换文案。
3. **新功能 2：杀后台断网重连自动恢复**
   - **目标**：App 被杀掉重启后，如果检测到有网络连接，自动尝试恢复之前未完成的下载任务。

## 2. 深度调研结论 (多智能体协同输出)

### 2.1 关于 SAF (Storage Access Framework) 与 Aria 引擎的兼容性
- **问题**：Aria (`me.laoyuyu.aria`) 核心是基于 `java.io.File` (绝对路径) 构建的，底层文件流无法直接写入 `content://` 格式的 SAF Uri。强行改造 Aria 源码成本极高。
- **最佳落地架构 (私有缓存 + 完成后静默迁移)**：
  1. Flutter 端使用 MethodChannel 调用 Android 原生的 `Intent.ACTION_OPEN_DOCUMENT_TREE` 让用户选择自定义目录。
  2. 原生端在 `onActivityResult` 获取 Uri，立刻调用 `contentResolver.takePersistableUriPermission(uri, ...)` 赋予持久读写权限，并将 Uri String 保存在 `SharedPreferences`。
  3. Aria 下载阶段：**依然将文件下载到 App 的私有目录**（如 `getExternalFilesDir`），确保多线程断点续传的 IO 性能和稳定性。
  4. 迁移阶段：在 Aria 原生端的 `@Download.onTaskComplete` 回调中，检查用户当前配置的目录偏好。如果是自定义 SAF 目录，则利用 `ContentResolver.openOutputStream` 将私有目录的文件通过后台 IO 流拷贝到 SAF 目录中，然后静默删除私有目录的原文件。

### 2.2 关于批量控制 (全部暂停/全部开始)
- **Aria 机制**：Aria 没有 `pauseAll`，统一使用 `stopAllTask()` 代表暂停保留进度。`cancelAllTask()` 会删除文件。
- **Flutter 状态防抖**：批量操作会瞬间触发大量 IO 与数据库操作。必须在 Flutter `DownloadManager` 引入互斥状态锁 `_isBatchProcessing`，点击后短暂禁用按钮；同时采用**乐观 UI 更新**（立刻在 Flutter 内存里把列表状态全部切为 Paused，给用户无延迟反馈），再异步通知原生引擎。
- **原生 MethodChannel**：在现有的 `com.piliplus/download` 通道中补充 `pauseAll` 映射至 `Aria.download(this).stopAllTask()`。

### 2.3 关于杀后台与网络自动恢复
- **Aria 原生行为**：Aria 内部 SQLite 完美记录了状态，但自身不会在进程销毁后自动恢复。
- **最佳落地架构**：
  在应用重新拉起初始化时（比如 Flutter 层的 `DownloadService.init`），通过 `connectivity_plus` 插件判断当前网络是否可用。如果可用（且满足用户设置的 Wi-Fi 偏好），则向原生发送 `resumeAll` 指令。由于 Aria 支持并发数限制，这一操作是安全的。

## 3. Subagent-Driven Development (SDD) 执行计划

我们将分阶段派发子智能体执行以下代码修改：

### 任务 1 (Task 1): Android SAF 原生目录挑选与权限持久化
- **目标**: `MainActivity.kt`
- **执行内容**:
  1. 添加 MethodChannel 调用 `selectCustomDirectory`，启动 `ACTION_OPEN_DOCUMENT_TREE`。
  2. 重写 `onActivityResult` 接管 Uri，调用 `takePersistableUriPermission` 并通过 SharedPrefs 持久化。
  3. 增加枚举标记用户的存储偏好 (Internal, SDCard, CustomSAF)。

### 任务 2 (Task 2): Aria 下载引擎的“后置迁移”与 pauseAll 指令
- **目标**: `MainActivity.kt`
- **执行内容**:
  1. 在 `@Download.onTaskComplete` 回调内增加逻辑：如果是自定义 SAF 模式，利用 `DocumentFile` 或流操作将视频从临时区搬运至 SAF Uri，随后删除原文件。
  2. 在 MethodChannel 里增加 `pauseAll` 方法映射。

### 任务 3 (Task 3): Flutter 设置页 "下载目录挑选器" 重构
- **目标**: Flutter 设置页面和本地存储配置服务
- **执行内容**:
  1. 废弃原有的单选 Switch，替换为弹窗或下拉选择菜单：【1.本机存储】、【2.SD卡(如有)】、【3.自定义目录】。
  2. 选择“自定义目录”时调用原生 `selectCustomDirectory` 并在界面显示挑选的路径名。

### 任务 4 (Task 4): Flutter "全部暂停/继续" 与重启网络恢复
- **目标**: 离线缓存界面 UI 及 `DownloadManager` 逻辑层
- **执行内容**:
  1. `DownloadManager` 新增 `toggleAllTasks()` 方法，引入 `isBatchProcessing` 锁和乐观 UI 机制。
  2. 在离线页面增加全局的 "全部暂停/继续" 控制按钮，状态由列表是否有下载中任务动态推导。
  3. 在 `DownloadManager` 初始化阶段检测 `ConnectivityResult`，若有网且非蜂窝（或允许蜂窝），则主动调用 `resumeAll()`。
