# Issue 04: Flutter Service Bridge - Playback Proxy & Storage Lost Fail-safe

**Goal**: Hook up the proxy for playback and handle edge cases like storage removal.

## Requirements:
1. **Playback Bridge**: In `lib/plugin/pl_player/controller.dart`, replace the raw `edl://` local paths with the Local HTTP Proxy URL created in Issue 02.
2. **Delete File**: Wire up the "Delete Video" action in the app to call `deleteSafFile` from Issue 01.
3. **Storage Lost Fail-safe**: Before starting a download in `DownloadService`, check if the selected directory exists. 
   - If missing (e.g. SD card pulled out), invoke `toggleAllTasks()` to Pause All.
   - Show Toast: "Storage Lost - Please reselect directory".
   - Reset the current active task's progress to 0.

## Blockers:
- 01-native-saf-enhancements
- 02-dart-http-proxy

## Status
Closed
