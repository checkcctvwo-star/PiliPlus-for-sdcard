# 华为鸿蒙 4.2 后台任务与功耗调度治理规范 (Background Tasks & PowerGenie)

> **知识库定位**：本文档沉淀自华为开发者联盟官方《Background Tasks Kit 接入规范》、《华为终端能效与功耗优化白皮书》，指导 AI Agent 针对长时间后台下载、大文件同步与状态自愈，提供符合鸿蒙 4.2 功耗审查标准的工程解决方案。

---

## 一、 华为后台功耗管控核心架构

鸿蒙 4.2 为了确保整机续航与前台流程度，内置了四重后台资源管控组件：

```
+-----------------------------------------------------------------------------------+
|                        华为后台资源与功耗调度链路                                    |
|                                                                                    |
| [应用切后台 / 熄屏]                                                                |
|       │ (无规范后台任务声明)                                                       |
|       ▼                                                                            |
| [PowerGenie 智能省电精灵] ──► 3~5分钟后触发 Cgroup Freezer (挂起所有线程)           |
|       │                                                                            |
|       ▼                                                                            |
| [内核防火墙 (eBPF/iptables)] ──► 阻断该 UID 网络通信 (抛出 SocketTimeoutException)  |
|       │                                                                            |
|       ▼ (若持续持有非法 Wakelock 或耗电超标)                                        |
| [iAware 智能资源感知] ──► 判定为"高耗电异常应用", 直接发送 SIGKILL 9 终止进程        |
+-----------------------------------------------------------------------------------+
```

---

## 二、 华为官方 Background Tasks Kit 核心规约

### 1. 长时任务 (Long-Time Task) 准入与绑定原则
适用于应用退到后台后，需要长时间运行且**用户可感知**的业务（如大文件数据传输、音视频播放、导航定位）。
- **场景严格相符**：必须使用 `dataSync`（数据传输）类型，严禁越界使用或用于恶意保活。
- **通知栏强绑定**：申请长时任务必须向系统提交一条常驻通知（Ongoing Notification），且允许动态更新进度。
- **用户行为联动**：若用户从通知栏手动清除该通知，应用必须主动调用 `stopForeground` 销毁任务，严禁防撤销。
- **及时释放**：任务下载完成或失败时，必须在 30 秒内主动调用取消长时任务，释放系统资源。

### 2. Android 12 AOSP 兼容层下的前台服务标准实现 (Kotlin)

在鸿蒙 4.2 兼容层中，三方应用必须通过带有 `dataSync` 属性的 Foreground Service 宣告长时意图：

```kotlin
// AndroidManifest.xml
<service
    android:name=".download.SafDownloadService"
    android:enabled="true"
    android:exported="false"
    android:foregroundServiceType="dataSync" />

// Kotlin 核心实现
class SafDownloadService : Service() {
    private val CHANNEL_ID = "download_channel_saf"

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createOngoingNotification("正在下载到扩展存储...", 0)
        
        // 关键：声明 FOREGROUND_SERVICE_TYPE_DATA_SYNC，向 PowerGenie 宣告合法意图
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        
        // 执行安全流式 I/O
        return START_NOT_STICKY
    }

    private fun createOngoingNotification(title: String, progress: Int): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setSmallIcon(R.drawable.ic_download)
            .setProgress(100, progress, false)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }
}
```

---

## 三、 唤醒锁 (WakeLock) 与断网重连自愈策略

### 1. 唤醒锁使用红线
- ❌ **严禁长时间持有无超时的 `PARTIAL_WAKE_LOCK`**：PowerGenie 会统计亮屏/熄屏下的唤醒锁持有时间比率（Wakelock Holding Ratio），一旦超过阈值直接加入黑名单并向用户弹窗“该应用频繁唤醒手机，建议立即休眠”。
- ✅ **带超时的精准释放范式**：
  ```kotlin
  wakeLock.acquire(30 * 60 * 1000L) // 强制设置最长超时（例如 30 分钟）
  try {
      doStreamDownload()
  } finally {
      if (wakeLock.isHeld) {
          wakeLock.release()
      }
  }
  ```

### 2. 杀后台恢复与 HTTP 416 幂等判别
- **磁盘真值扫描**：应用冷启动时，扫描私有沙盒与 SAF 目录下的 `.part` 暂存文件大小。
- **断点重试发起**：添加 HTTP 头 `Range: bytes=${localFileSize}-`。
- **HTTP 416 处理准则**：
  - 若服务端返回 `HTTP 416 Range Not Satisfiable`：
    - 若 `localFileSize >= totalFileSize`，说明文件已下载完毕，直接进入 Stage 2 Commit 提交；
    - 若 `localFileSize < totalFileSize`，判定本地分片脏损坏，清空本地分片后从头全量拉取。
