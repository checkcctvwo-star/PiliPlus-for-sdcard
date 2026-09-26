# Handoff: Black Screen/Audio Desync Bug in SD Card Playback

## 1. 架构背景与当前状态 (Context & Architecture)
在之前的 Session 中，我们成功重构了 PiliPlus 的 SD 卡（SAF）外置存储方案。
由于 `media_kit` (libmpv) 无法直接读取 Android 11+ 的 `content://` URI，我们实现了一个 **Dart 层的本地 HTTP 代理微服务 (`LocalProxyServer`)**。
播放器通过 `http://127.0.0.1:<port>/stream?path=<saf_uri>` 访问代理，代理通过 `File.openRead` 以及 HTTP 206 `Partial Content` / `Range` header 动态返回视频流数据。

**参考文档与源码：**
- 架构设计: `.scratch/sdcard-saf-storage-refactor/SPEC.md`
- 代理源码: `lib/services/proxy/local_proxy_server.dart`

## 2. 待解决的核心 Bug (The Bug)
**症状：**
用户在播放下载到 SD 卡的超大视频（例如 40 分钟的 4K 视频）时，视频前 60%-70% 播放完全正常（音画同步）。但在最后 20%-30% 的进度时，**视频画面突然停止/黑屏，但声音（音频）仍在正常继续播放**。
这种情况通常出现在因锁屏或切后台导致下载任务曾被中断的场景中。

**核心诊断线索与假设 (Hypotheses)：**
1. **DASH 格式下载不完整（最大嫌疑）**：
   Bilibili 的 DASH 格式将视频和音频分成两个独立文件（`video.m4s` 和 `audio.m4s`）。4K 视频的 `video.m4s` 极大（可能 >2GB），而 `audio.m4s` 很小（约 50MB）。
   如果系统在后台杀死了下载进程，很可能 50MB 的音频已经 100% 下载完毕，而 2GB 的视频只下载了 70%。
   当代理端流式读取到 70% 时遇到 `EOF (End of File)`，导致视频轨提前结束（黑屏），而音频轨继续播放。
   - **验证方案**：需编写测试脚本或增加日志，打印 `video.m4s` 和 `audio.m4s` 在本地磁盘上的真实 File Size，并与 API 返回的 Content-Length 做对比。
2. **LocalProxyServer 的大文件溢出或 Range 解析 Bug**：
   HTTP 代理的 `Range` header 解析逻辑或 `File.openRead(start, end)` 可能在处理大于 2GB 的超大文件时发生了溢出或截断。
   - **验证方案**：检查 proxy server 日志，确认大文件的末尾 `Range` 请求是否返回了正确的 206 状态码和 Content-Length。

## 3. Suggested Skills (下一步技能建议)
接收此交接文档的 Agent 应立即使用以下技能进行排查：
- **`/diagnosing-bugs`**: 严格遵循系统的 debug 循环。在给出长篇大论的假设前，必须首先在代码中插入 Log 或编写验证脚本（Tight Feedback Loop），确认到底是“文件尺寸残缺”还是“代理服务器溢出”。

## 4. Next Steps for the Fresh Agent
1. 阅读 `lib/services/proxy/local_proxy_server.dart`。
2. 建议用户提供一个复现该问题的视频的真实路径，或者指导用户在播放发生黑屏时截取 `adb logcat` 和 Proxy 端的内部日志。
3. 检查 B 站下载器 (`lib/services/download/` 相关模块) 是如何处理断点续传的，以及是否会在文件不完整时误标为“已完成”。
