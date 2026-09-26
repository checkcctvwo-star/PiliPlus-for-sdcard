# Issue 02: Dart Local HTTP Proxy Server for SAF Video Streaming

**Goal**: Implement a local HTTP proxy in Dart to stream videos for `media_kit`.

## Requirements:
1. **Proxy Server**: Create `lib/services/proxy/local_proxy_server.dart`.
2. **HttpServer**: Bind to `127.0.0.1:0` (random port).
3. **Range Headers**: Must correctly parse `Range: bytes=start-end`, respond with `206 Partial Content`, and set `Content-Range`.
4. **SAF Reading**: Read local files or SAF files using Dart `File.openRead(start, end)` (assuming permissions are correctly handled or native fallback if Dart `File` fails on SAF). *Wait, Dart File doesn't work on SAF `content://` URIs. We may need a Native method to stream bytes, OR since we use proxy, maybe we can copy it to temp cache? No, handoff doc said "Dart 层通过其自带的虚拟机权限适配，合法读取 SD 卡上的真实文件字节流 (File.openRead())". Let's try Dart File first as per the handoff doc.*
5. **Lifecycle**: Start server on App Init, close on App Dispose.

## Blockers:
- None

## Status
Completed
