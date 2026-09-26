# PiliPlus SAF & SD Card Storage Refactor Specification

## Overview
This feature implements comprehensive support for Android Scoped Storage (SAF) / external SD cards for downloading and playing videos in PiliPlus. 

## Functional Requirements
1. **Settings & SD Card Detection**: Detect available external storage (SD cards). Allow selection if present, grey out if not.
2. **File Migration with Real Progress**: When changing download directory, auto-migrate existing cache.
   - If > 500MB, prompt user first.
   - Show real-time MBs transferred progress bar.
   - Must have a "Cancel" button. 
   - Migration must be safe: Cooperative cancellation via Kotlin Coroutines. Only delete old files upon 100% success.
3. **Local HTTP Proxy for Playback**: `media_kit` C++ cannot read `content://` SAF URIs directly. A local Dart `HttpServer` (127.0.0.1:0) will intercept video streams, resolving local files or SAF files and responding with HTTP `206 Partial Content` (Range headers).
4. **App Delete Sync**: Deleting a downloaded video from the app UI must also physically delete the SAF file or local file. Handles `SafNotFoundException` gracefully.
5. **Storage Lost Exception**: If an SD card is pulled out mid-use, pause active downloads automatically, throw "Storage Lost", and reset their download progress. Utilize existing `hasActiveTask ? "全部暂停" : "全部开始"` logic.

## Architecture
- **Native (Kotlin)**: MethodChannels for `checkSdCardAvailable`, `deleteSafFile`, `startMigration` (with EventChannel for progress).
- **Dart Services**: Proxy Server using `dart:io` `HttpServer`. `path_provider` for initial storage list.
- **State/UI**: Modal barrier for migration, preventing background tasks from interfering.

## Tickets
- [ ] 01-native-saf-enhancements
- [ ] 02-dart-http-proxy
- [ ] 03-flutter-ui-migration
- [ ] 04-flutter-service-bridge
