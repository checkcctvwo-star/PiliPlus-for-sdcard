# 鸿蒙 4.2 / Android 12 底层存储架构与大文件 I/O 知识库

> **知识库定位**：本文档沉淀自华为开发者联盟官方《Core File Kit 开发指南》、《用户文件访问框架规范》以及 Linux 内核/AOSP 底层存储实现，作为 AI Agent 在鸿蒙 4.2 设备（如 MatePad Pro）上进行存储架构设计、大文件写入排障与代码自愈的核心参考标准。

---

## 一、 文件写入大小限制的本质：六重底层漏斗模型

在鸿蒙 4.2（基于 Android 12 AOSP 兼容层 API 31/32 与 OpenHarmony 4.0）中，系统不存在全局统一硬编码的“例如 2GB 或 4GB”限制。大文件写入失败由以下六层机制共同作用：

### 1. 物理文件系统格式层（FAT32 4GB 物理硬顶）
- **FAT32 规范**：目录项中文件大小字段为 32 位无符号整数（DWORD），物理极限为 $2^{32} - 1 = 4,294,967,295 \text{ 字节}$（约 4GB - 1B）。
  - 超限后果：Linux 内核 FAT 驱动抛出 `-EFBIG`（File too large, errno 27），应用层抛出 `java.io.IOException: write failed: EFBIG`。
- **exFAT 规范（华为平板外置 SD 卡标配）**：
  - 单文件理论上限为 $16\text{EB}$，现实中对超大单文件（数十至数百 GB）完全无限制。
  - **真机实测**：MatePad Pro 外置 SD 卡（`/dev/block/vold/public:179:1`）底层格式为 `exFAT`，彻底豁免 FAT32 4GB 物理硬顶。
- **内部存储 (ext4 / F2FS)**：
  - F2FS 单文件上限 3.94TB，ext4 单文件上限 16TB，完全不受 4GB 限制。

### 2. C 运行库与内核寻址指针（LFS 规范）
- **64 位进程架构 (`arm64-v8a`)**：原生 `sizeof(off_t) = 8`，寻址空间达 9.22EB，无 2GB 溢出问题。
- **32 位 Legacy 架构 (`armeabi-v7a`)**：
  - 若编译时未显式指定宏 `-D_FILE_OFFSET_BITS=64`，`off_t` 默认为 32 位带符号整型，在 **$2\text{GB} - 1\text{B}$** 处截断抛出 `EOVERFLOW`（Value too large for defined data type, errno 75）。

### 3. 应用进程堆内存 OOM（非流式全量缓冲陷阱）
- **内存配额**：鸿蒙 4.2 默认 Dalvik 堆内存限制为 192MB~256MB（`android:largeHeap="true"` 仅提升至 512MB）。
- **致命反例**：直接将网络流读入单一内存字节数组（如 `response.body().bytes()` 或 Dart `Uint8List`）。
- **标准规约**：必须采用 **64KB~128KB 缓冲区的 Streaming 管道** 边读边写。

### 4. Binder IPC 1MB 事务墙与 ParcelFileDescriptor
- **Binder 物理上限**：内核 Binder 共享缓冲区上限固定为 **1MB**。通过 AIDL 传递大型数据块会抛出 `android.os.TransactionTooLargeException`。
- **破局方案（PFD 句柄传递）**：
  - SAF (`ContentResolver.openOutputStream()`) 不通过 Binder 传输字节流，而是传递 `ParcelFileDescriptor` (PFD)。
  - 内核 Binder 驱动在接收进程安装新的 `fd`，直连内核 VFS 管道，彻底绕过 Binder 1MB 限制。

### 5. 用户态 FUSE 延迟与 sdcardfs 调度
- **FUSE 上下文切换**：外置 SD 卡必须跨用户态 `MediaProvider` 守护进程鉴权。低速 SD 卡（Class 4/10）写入会导致 I/O 拥塞，触发线程 D 状态与 ANR。
- **Android 12 FUSE Passthrough**：内部存储享有直通加速，而外置 SD 卡 SAF 虚拟树无法完全直通，必须控制高频小 I/O。

### 6. 华为 PowerGenie / iAware 后台防偷跑机制
- 三方应用退到后台、熄屏约 3~5 分钟后，PowerGenie 启动 Cgroup Freezer 挂起进程并阻断网络，引发 `SocketTimeoutException`。
- **合规方案**：后台长时间大文件下载必须挂载 `Foreground Service`，详见后台任务规范。

---

## 二、 浏览器公共 Download 目录免限制的技术解密

| 维度 | 普通三方 APP | 浏览器 / 系统下载通道 |
| :--- | :--- | :--- |
| **执行实体** | App 自身进程，受生命周期与退火限制 | **系统特权服务** `com.android.providers.downloads` (UID: system/shared) |
| **生命周期** | 划掉卡片时立即被 kill | **彻底解耦**，浏览器划卡强杀后系统服务依然独立运行 |
| **功耗白名单** | 退后台 3~5 分钟被 Freeze 或断网 | **享有最高省电白名单**，合法持有系统唤醒锁 (`PARTIAL_WAKE_LOCK`) |
| **硬件存储介质** | 外置 SD 卡（低速总线、FUSE 跨进程桥接） | **内部板载 UFS 闪存**（顺序写高达 1500MB/s+） |
| **空间预分配** | 频繁追加写导致碎片化与刷盘颠簸 | 原生支持 **`fallocate()` 一次性预分配连续物理块**，无元数据颠簸 |

---

## 三、 外置物理 SD 卡两大访问路径对比与工程决议

### 路径 A：免权限私有沙盒直写 (`Context.getExternalFilesDirs(null)[1]`)
- **真实路径**：`/storage/FBF9-F18E/Android/data/com.example.piliplus/files`
- **所有权**：系统自动打上应用专属 UID（如 `u0_a266`），权限为 `drwxrwx---`。
- **优势**：
  - 100% 支持标准 POSIX API（`dart:io File` / `fopen` / `FileInputStream`）。
  - 零权限弹窗，原生硬件物理读写速度。
- **代价**：**应用卸载时随之被系统 vold 自动清空**。

### 路径 B：持久化保留 SAF 虚拟树 (`Intent.ACTION_OPEN_DOCUMENT_TREE`)
- **真实路径**：`content://com.android.externalstorage.documents/tree/...`
- **优势**：保存在用户指定的自定义根目录或公共文件夹，应用卸载数据不丢。
- **代价与架构防线**：
  - 目录遍历与文件创建需跨进程 Binder RPC，吞吐量降低 30%~50%。
  - 底层 C++ 播放器（`media_kit`/`libmpv`）无法识别 `content://`，需通过本地环回代理（`http://127.0.0.1:<port>`）桥接。
  - **核心铁律（两阶段提交流水线）**：
    1. **Staging**：网络流高速下载到应用私有沙盒临时目录（`cache/*.part`），支持断点续传与 MD5 校验。
    2. **Commit**：校验通过后，在目标 SAF 目录下创建临时占位文件（`.<name>.tmp`），通过 `openOutputStream` 管道一次性写入，刷盘后原子重命名。
