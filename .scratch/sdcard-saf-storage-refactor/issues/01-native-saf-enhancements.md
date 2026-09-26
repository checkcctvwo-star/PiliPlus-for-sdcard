# Issue 01: Native Kotlin SAF Enhancements

**Goal**: Implement the native Android bridge for SD card operations.

## Requirements:
1. **MethodChannel `deleteSafFile(uri)`**: Delete a `content://` URI using Android `DocumentFile` or `ContentResolver`. Catch and swallow `FileNotFoundException`.
2. **MethodChannel `startMigration(oldPath, newUri)`**: 
   - Start a Kotlin Coroutine (IO Dispatcher).
   - Read files from `oldPath` and copy them to `newUri` using an 8KB buffer.
   - Use `ensureActive()` inside the while loop for cooperative cancellation.
   - Communicate progress `(bytesCopied / totalBytes) * 100` via `EventChannel("saf_migration_progress")`.
   - On completion, delete `oldPath` files.
3. **MethodChannel `cancelMigration()`**: Cancels the coroutine Job. The cancellation catch block must rollback (delete) any partially copied files in the `newUri` directory.

## Blockers:
- None

## Status
Open
