package com.example.piliplus

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager.LayoutParams
import androidx.documentfile.provider.DocumentFile
import com.arialyy.aria.core.Aria
import com.example.piliplus.media.MediaMuxerBridge
import com.example.piliplus.storage.SafStorageBridge
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val TAG = "MainActivity"
    private val REQUEST_CODE_OPEN_DOCUMENT_TREE = 42
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val safExecutor = Executors.newFixedThreadPool(1)

    private var migrationJob: Job? = null
    private var progressSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "saf_migration_progress").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.piliplus/download").setMethodCallHandler { call, result ->
            when (call.method) {
                // ── DASH Media Muxing ────────────────────────────────────────────
                "mergeDashMedia" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val audioPath = call.argument<String>("audioPath")
                    val outputPath = call.argument<String>("outputPath")
                    val forceAudioTranscode = call.argument<Boolean>("transcodeAudioToAac") ?: false

                    if (videoPath == null || audioPath == null || outputPath == null) {
                        result.error("INVALID_ARGS", "videoPath, audioPath, or outputPath is null", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.Main).launch {
                        val muxResult = MediaMuxerBridge.mergeDash(
                            videoPath = videoPath,
                            audioPath = audioPath,
                            outputPath = outputPath,
                            forceAudioTranscode = forceAudioTranscode
                        )
                        if (muxResult.isSuccess) {
                            result.success(true)
                        } else {
                            result.error("MUX_FAILED", muxResult.exceptionOrNull()?.message, null)
                        }
                    }
                }

                // ── Staging to Target Atomic Commit ──────────────────────────────
                "commitStagingEntry" -> {
                    val stagingEntryPath = call.argument<String>("stagingEntryPath")
                    val targetType = call.argument<Int>("targetType") ?: 0
                    val targetBaseDir = call.argument<String>("targetBaseDir")
                    val relativePath = call.argument<String>("relativePath")

                    if (stagingEntryPath == null || targetBaseDir == null || relativePath == null) {
                        result.error("INVALID_ARGS", "Missing staging commit args", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val stagingDir = File(stagingEntryPath)
                            if (!stagingDir.exists() || !stagingDir.isDirectory) {
                                withContext(Dispatchers.Main) { result.error("DIR_NOT_FOUND", "Staging dir missing", null) }
                                return@launch
                            }

                            if (targetType == 2) {
                                // SAF Mode: commit all files recursively into SAF DocumentFile tree
                                val committedUris = mutableMapOf<String, String>()
                                val files = stagingDir.walkTopDown().filter { it.isFile }.toList()
                                for (file in files) {
                                    val fileSubRel = file.relativeTo(stagingDir).path
                                    val subFolder = if (fileSubRel.contains(File.separator)) {
                                        "$relativePath/${fileSubRel.substringBeforeLast(File.separator)}"
                                    } else {
                                        relativePath
                                    }
                                    val commitRes = SafStorageBridge.commitFileToSaf(
                                        context = this@MainActivity,
                                        srcFilePath = file.absolutePath,
                                        treeUriString = targetBaseDir,
                                        relativeSubDirPath = subFolder,
                                        fileName = file.name
                                    )
                                    if (commitRes.isSuccess) {
                                        val uriStr = commitRes.getOrNull()!!
                                        committedUris[file.name] = uriStr
                                        committedUris[fileSubRel] = uriStr
                                    } else {
                                        if (file.name == "0.mp4" || file.name.endsWith(".m4s")) {
                                            throw commitRes.exceptionOrNull() ?: Exception("Failed to commit media ${file.name} to SAF")
                                        } else {
                                            Log.w(TAG, "Non-critical file commit warning for ${file.name}", commitRes.exceptionOrNull())
                                        }
                                    }
                                }
                                stagingDir.deleteRecursively()
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to true, "safFileUris" to committedUris))
                                }
                            } else {
                                // POSIX Mode (0: internal app storage, 1: external SD card sandbox)
                                val targetDir = File(targetBaseDir, relativePath)
                                targetDir.mkdirs()
                                stagingDir.copyRecursively(targetDir, overwrite = true)
                                stagingDir.deleteRecursively()
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to true, "safFileUris" to null))
                                }
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "commitStagingEntry failed", e)
                            withContext(Dispatchers.Main) { result.error("COMMIT_FAILED", e.message, e.toString()) }
                        }
                    }
                }

                // ── SAF URI Resolution and Direct FD Bridging ────────────────────
                "resolveContentUriToPath" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        val path = SafStorageBridge.resolveSafUriToPath(this@MainActivity, uriString)
                        result.success(path)
                    } else {
                        result.error("INVALID_ARGS", "uri is null", null)
                    }
                }

                "openSafFd" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        val fd = SafStorageBridge.openSafFd(this@MainActivity, uriString)
                        result.success(fd)
                    } else {
                        result.error("INVALID_ARGS", "uri is null", null)
                    }
                }

                "readSafBytes" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        CoroutineScope(Dispatchers.IO).launch {
                            val bytes = SafStorageBridge.readSafBytes(this@MainActivity, uriString)
                            withContext(Dispatchers.Main) { result.success(bytes) }
                        }
                    } else {
                        result.error("INVALID_ARGS", "uri is null", null)
                    }
                }

                // ── SAF Tree Recursive Scanning ──────────────────────────────────
                "scanSafEntries" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("INVALID_ARGS", "uri is null", null)
                        return@setMethodCallHandler
                    }
                    CoroutineScope(Dispatchers.IO).launch {
                        val list = SafStorageBridge.scanEntriesFromSaf(this@MainActivity, uriString)
                        withContext(Dispatchers.Main) { result.success(list) }
                    }
                }

                // ── Calculate Directory Size (POSIX or SAF) ──────────────────────
                "calculateDirSize" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(0L)
                        return@setMethodCallHandler
                    }
                    CoroutineScope(Dispatchers.IO).launch {
                        val size = if (path.startsWith("content://")) {
                            SafStorageBridge.calculateSafSize(this@MainActivity, path)
                        } else {
                            val dir = File(path)
                            if (dir.exists()) {
                                dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
                            } else {
                                0L
                            }
                        }
                        withContext(Dispatchers.Main) { result.success(size) }
                    }
                }

                // ── External SD Card Path Bridge ─────────────────────────────────
                "getExternalSDCardPath" -> {
                    val externalDirs = getExternalFilesDirs(null)
                    var foundPath: String? = null
                    if (externalDirs.size > 1) {
                        for (i in 1 until externalDirs.size) {
                            val dir = externalDirs[i]
                            if (dir != null) {
                                val sdCardDownloadDir = File(dir, "download")
                                if (!sdCardDownloadDir.exists()) {
                                    sdCardDownloadDir.mkdirs()
                                }
                                foundPath = sdCardDownloadDir.absolutePath
                                break
                            }
                        }
                    }
                    result.success(foundPath)
                }

                // ── Aria Download Control ────────────────────────────────────────
                "startDownload" -> {
                    val url = call.argument<String>("url")
                    val path = call.argument<String>("path")
                    if (url != null && path != null) {
                        Aria.download(this).load(url).setFilePath(path).create()
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "url or path is null", null)
                    }
                }
                "pauseDownload", "pauseAll" -> {
                    Aria.download(this).stopAllTask()
                    result.success(true)
                }
                "resumeAll" -> {
                    Aria.download(this).resumeAllTask()
                    result.success(true)
                }
                "resumeFailedTasks" -> {
                    val notComplete = Aria.download(this).allNotCompleteTask
                    if (notComplete != null) {
                        for (task in notComplete) {
                            if (task.state == com.arialyy.aria.core.inf.IEntity.STATE_FAIL || task.state == com.arialyy.aria.core.inf.IEntity.STATE_WAIT) {
                                Aria.download(this).load(task.id).resume()
                            }
                        }
                    }
                    result.success(true)
                }
                "getUnfinishedTasks" -> {
                    val notComplete = Aria.download(this).allNotCompleteTask
                    val resultList = mutableListOf<Map<String, Any?>>()
                    if (notComplete != null) {
                        for (task in notComplete) {
                            val map = mapOf(
                                "id" to task.id,
                                "filePath" to task.filePath,
                                "currentProgress" to task.currentProgress,
                                "fileSize" to task.fileSize,
                                "state" to task.state,
                                "extendField" to task.str
                            )
                            resultList.add(map)
                        }
                    }
                    result.success(resultList)
                }

                // ── SAF Storage Access Framework ─────────────────────────────────
                "selectCustomDirectory" -> {
                    pendingDirectoryResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    startActivityForResult(intent, REQUEST_CODE_OPEN_DOCUMENT_TREE)
                }
                "getCustomDirectoryUri" -> {
                    val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                    val uriString = prefs.getString("custom_saf_uri", null)
                    result.success(uriString)
                }
                "clearCustomDirectory" -> {
                    val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                    prefs.edit().remove("custom_saf_uri").apply()
                    result.success(true)
                }
                "saveToSafDirectory" -> {
                    val srcPath = call.argument<String>("path")
                    val targetDir = call.argument<String>("targetDir")
                    if (srcPath == null || srcPath.isEmpty()) {
                        result.error("INVALID_ARGS", "path is null", null)
                        return@setMethodCallHandler
                    }
                    safExecutor.execute {
                        try {
                            val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                            val safUriString = prefs.getString("custom_saf_uri", null)
                            if (safUriString == null) {
                                runOnUiThread { result.error("NO_SAF_URI", "custom SAF directory is not set", null) }
                                return@execute
                            }
                            val srcFile = File(srcPath)
                            val fileName = srcFile.name
                            val relativePath = targetDir ?: ""
                            CoroutineScope(Dispatchers.IO).launch {
                                val commitRes = SafStorageBridge.commitFileToSaf(
                                    context = this@MainActivity,
                                    srcFilePath = srcFile.absolutePath,
                                    treeUriString = safUriString,
                                    relativeSubDirPath = relativePath,
                                    fileName = fileName
                                )
                                withContext(Dispatchers.Main) {
                                    if (commitRes.isSuccess) {
                                        result.success(commitRes.getOrNull())
                                    } else {
                                        result.error("SAVE_FAILED", commitRes.exceptionOrNull()?.message, null)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", e.message, e.toString()) }
                        }
                    }
                }
                "deleteSafFile" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val uri = Uri.parse(uriString)
                            val documentFile = DocumentFile.fromSingleUri(this@MainActivity, uri)
                            if (documentFile != null && documentFile.exists()) {
                                documentFile.delete()
                            } else {
                                contentResolver.delete(uri, null, null)
                            }
                            result.success(true)
                        } catch (e: FileNotFoundException) {
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DELETE_FAILED", e.message, e.toString())
                        }
                    } else {
                        result.error("INVALID_ARGS", "uri is null", null)
                    }
                }
                "scanSafDirectory" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("INVALID_ARGS", "uri is null", null)
                        return@setMethodCallHandler
                    }
                    safExecutor.execute {
                        try {
                            val uri = Uri.parse(uriString)
                            val root = DocumentFile.fromTreeUri(this@MainActivity, uri)
                            val dirNames = root?.listFiles()?.filter { it.isDirectory }?.mapNotNull { it.name } ?: emptyList()
                            runOnUiThread { result.success(dirNames) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SCAN_FAILED", e.message, e.toString()) }
                        }
                    }
                }
                "startMigration" -> {
                    val oldPath = call.argument<String>("oldPath")
                    val newPath = call.argument<String>("newPath") ?: call.argument<String>("newUri")
                    val newType = call.argument<Int>("newType") ?: 0

                    if (oldPath == null || newPath == null) {
                        result.error("INVALID_ARGS", "oldPath or newPath is null", null)
                        return@setMethodCallHandler
                    }

                    migrationJob?.cancel()

                    migrationJob = CoroutineScope(Dispatchers.IO).launch {
                        try {
                            // If oldPath is not a valid directory or is SAF URI, no POSIX files to copy; succeed directly
                            val oldDir = File(oldPath)
                            if (!oldDir.exists() || !oldDir.isDirectory) {
                                withContext(Dispatchers.Main) {
                                    progressSink?.success(mapOf("transferred" to 0.0, "total" to 0.0))
                                    result.success(true)
                                }
                                return@launch
                            }

                            val allFiles = mutableListOf<File>()
                            fun collectFiles(dir: File) {
                                val files = dir.listFiles() ?: return
                                for (f in files) {
                                    if (f.isDirectory) collectFiles(f)
                                    else allFiles.add(f)
                                }
                            }
                            collectFiles(oldDir)

                            val totalBytes = allFiles.sumOf { it.length() }.toDouble()
                            var bytesCopied = 0.0

                            if (allFiles.isEmpty()) {
                                withContext(Dispatchers.Main) {
                                    progressSink?.success(mapOf("transferred" to 0.0, "total" to 0.0))
                                    result.success(true)
                                }
                                return@launch
                            }

                            for (file in allFiles) {
                                ensureActive()
                                val relPath = file.absolutePath.removePrefix(oldDir.absolutePath).removePrefix("/")
                                val parentRel = if (relPath.contains(File.separator)) relPath.substringBeforeLast(File.separator) else ""
                                val fileName = file.name

                                if (newType == 2) {
                                    val commitRes = SafStorageBridge.commitFileToSaf(
                                        context = this@MainActivity,
                                        srcFilePath = file.absolutePath,
                                        treeUriString = newPath,
                                        relativeSubDirPath = parentRel,
                                        fileName = fileName
                                    )
                                    if (commitRes.isFailure) {
                                        throw commitRes.exceptionOrNull() ?: Exception("Migration failed for $fileName")
                                    }
                                } else {
                                    val destFile = File(newPath, relPath)
                                    destFile.parentFile?.mkdirs()
                                    file.copyTo(destFile, overwrite = true)
                                    file.delete()
                                }

                                bytesCopied += file.length()
                                withContext(Dispatchers.Main) {
                                    progressSink?.success(mapOf(
                                        "transferred" to bytesCopied,
                                        "total" to totalBytes,
                                        "currentFile" to relPath
                                    ))
                                }
                            }

                            fun deleteRecursively(f: File) {
                                if (f.isDirectory) {
                                    f.listFiles()?.forEach { deleteRecursively(it) }
                                }
                                f.delete()
                            }
                            deleteRecursively(oldDir)

                            withContext(Dispatchers.Main) {
                                progressSink?.success(mapOf("transferred" to totalBytes, "total" to totalBytes))
                                result.success(true)
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.e(TAG, "startMigration error", e)
                            withContext(Dispatchers.Main) {
                                result.error("MIGRATION_FAILED", e.message, e.toString())
                            }
                        } finally {
                            if (migrationJob == coroutineContext[Job]) {
                                migrationJob = null
                            }
                        }
                    }
                }
                "cancelMigration" -> {
                    migrationJob?.cancel()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_OPEN_DOCUMENT_TREE) {
            if (resultCode == RESULT_OK) {
                data?.data?.let { uri ->
                    val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    contentResolver.takePersistableUriPermission(uri, flags)
                    val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                    prefs.edit().putString("custom_saf_uri", uri.toString()).apply()
                    pendingDirectoryResult?.success(uri.toString())
                    pendingDirectoryResult = null
                } ?: run {
                    pendingDirectoryResult?.error("NO_URI", "No URI returned", null)
                    pendingDirectoryResult = null
                }
            } else {
                pendingDirectoryResult?.success(null)
                pendingDirectoryResult = null
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
