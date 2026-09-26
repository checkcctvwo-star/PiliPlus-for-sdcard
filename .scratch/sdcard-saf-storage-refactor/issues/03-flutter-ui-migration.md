# Issue 03: Flutter UI - Settings Migration Dialog & SD Card Detection

**Goal**: Implement the Settings UI for Storage change and migration flow.

## Requirements:
1. **SD Card Detection**: In the Settings page, use `path_provider` to get external storage directories. If SD card is not present, grey out the "SD Card" option.
2. **Size Check**: When directory is changed, calculate size of existing cache.
   - If > 500MB, show confirmation dialog ("Moving X GB, this might take time...").
   - If < 500MB, skip confirmation and show migration progress directly.
3. **Migration Progress UI**: 
   - Show a non-dismissible modal with a `LinearProgressIndicator`.
   - Show exact MBs transferred / total MBs.
   - Provide a "Cancel" button.
   - Listen to `EventChannel("saf_migration_progress")`.
4. **Integration**: Call `startMigration` from Issue 01.

## Blockers:
- 01-native-saf-enhancements

## Status
Closed
