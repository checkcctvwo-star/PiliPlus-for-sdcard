package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.content.Context
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.arialyy.aria.core.Aria
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import kotlinx.coroutines.*

enum class StoragePreference {
    Internal, SDCard, CustomSAF
}

class MainActivity : AudioServiceActivity() {
    private val REQUEST_CODE_OPEN_DOCUMENT_TREE = 42
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val safExecutor = java.util.concurrent.Executors.newFixedThreadPool(1)

    // Holds open ParcelFileDescriptors for SAF URIs whose real path could not be
    // resolved via /proc/self/fd (rare on SD cards with strict SELinux). They must
    // stay open as long as the mpv /proc/self/fd/<n> path is in use.
    private val safPfds = mutableListOf<android.os.ParcelFileDescriptor>()
    
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
                "pauseDownload" -> {
                    Aria.download(this).stopAllTask()
                    result.success(true)
                }
                "pauseAll" -> {
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
                "getExternalSDCardPath" -> {
                    val externalDirs = getExternalFilesDirs(null)
                    if (externalDirs.size > 1 && externalDirs[1] != null) {
                        result.success(externalDirs[1]!!.absolutePath)
                    } else {
                        result.success(null)
                    }
                }
                "selectCustomDirectory" -> {
                    pendingDirectoryResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    startActivityForResult(intent, REQUEST_CODE_OPEN_DOCUMENT_TREE)
                }
                "getCustomDirectoryUri" -> {
                    val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                    val uriString = prefs.getString("custom_saf_uri", null)
                    result.success(uriString)
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
                            val root = DocumentFile.fromTreeUri(this, Uri.parse(safUriString))
                            if (root == null) {
                                runOnUiThread { result.error("SAF_INVALID", "cannot resolve SAF directory", null) }
                                return@execute
                            }
                            var dir: DocumentFile? = root
                            if (targetDir != null && targetDir.isNotEmpty()) {
                                for (segment in targetDir.split("/")) {
                                    if (segment.isEmpty()) continue
                                    val current = dir
                                    if (current == null) {
                                        break
                                    }
                                    val childDir = current.findFile(segment)
                                    dir = if (childDir != null && childDir.isDirectory) {
                                        childDir
                                    } else {
                                        current.createDirectory(segment)
                                    }
                                    if (dir == null) {
                                        runOnUiThread { result.error("CREATE_DIR_FAILED", "cannot create directory $segment", null) }
                                        return@execute
                                    }
                                }
                            }
                            val dirResolved = dir
                            if (dirResolved == null) {
                                runOnUiThread { result.error("CREATE_DIR_FAILED", "cannot resolve target directory", null) }
                                return@execute
                            }
                            val srcFile = File(srcPath)
                            val fileName = srcFile.name
                            val mimeType = getMimeTypeFromExtension(fileName)
                            val tmpName = ".$fileName.tmp"
                            var newFile = dirResolved.findFile(tmpName)
                            if (newFile == null) {
                                newFile = dirResolved.createFile(mimeType, tmpName)
                            }
                            if (newFile == null) {
                                runOnUiThread { result.error("CREATE_FILE_FAILED", "cannot create file $fileName", null) }
                                return@execute
                            }
                            try {
                                val os = contentResolver.openOutputStream(newFile.uri)
                                    ?: throw java.io.IOException("Failed to open SAF output stream (returned null)")
                                os.use { outStream ->
                                    FileInputStream(srcFile).use { inputStream ->
                                        inputStream.copyTo(outStream)
                                        outStream.flush()
                                    }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("SAF_COPY_FAILED", e.message, e.toString()) }
                                return@execute
                            }
                            dirResolved.findFile(fileName)?.delete()
                            if (!newFile.renameTo(fileName)) {
                                runOnUiThread { result.error("SAF_RENAME_FAILED", "renameTo returned false", null) }
                                return@execute
                            }
                            runOnUiThread { result.success(newFile.uri.toString()) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAF_COPY_FAILED", e.message, e.toString()) }
                        }
                    }
                }
                "clearCustomDirectory" -> {
                    val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
                    prefs.edit().remove("custom_saf_uri").apply()
                    result.success(true)
                }
                // ── SAF Playback Bridge ──────────────────────────────────────────────
                // Inspired by mpv-android/Utils.kt findRealPath() technique.
                // Opens the SAF content:// URI and resolves /proc/self/fd/<n> to the
                // real absolute path so libmpv (media_kit) can open the file directly.
                "resolveContentUriToPath" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("INVALID_ARGS", "uri is null", null)
                        return@setMethodCallHandler
                    }
                    safExecutor.execute {
                        try {
                            val uri = Uri.parse(uriString)
                            val pfd = contentResolver.openFileDescriptor(uri, "r")
                            if (pfd == null) {
                                runOnUiThread { result.error("OPEN_FAILED", "Cannot open URI: $uriString", null) }
                                return@execute
                            }
                            val fd = pfd.fd
                            val procPath = "/proc/self/fd/$fd"
                            // Try to resolve the symlink to a real absolute path.
                            // If it resolves to a non-/proc path and is readable, we can
                            // close the PFD immediately (real file remains on disk).
                            val resolvedPath: String = try {
                                val canonical = java.io.File(procPath).canonicalPath
                                if (!canonical.startsWith("/proc") && java.io.File(canonical).canRead()) {
                                    pfd.close() // PFD no longer needed
                                    canonical
                                } else {
                                    // Could not resolve to real path (e.g. strict SELinux).
                                    // Keep PFD open; mpv can open /proc/self/fd/<n> directly.
                                    synchronized(safPfds) { safPfds.add(pfd) }
                                    procPath
                                }
                            } catch (e: Exception) {
                                // Fallback: keep PFD open and give mpv the proc path.
                                synchronized(safPfds) { safPfds.add(pfd) }
                                procPath
                            }
                            runOnUiThread { result.success(resolvedPath) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("RESOLVE_ERROR", e.message, e.toString()) }
                        }
                    }
                }
                // Call this when playback finishes to release any held FDs.
                "clearSafPfds" -> {
                    safExecutor.execute {
                        synchronized(safPfds) {
                            safPfds.forEach { try { it.close() } catch (_: Exception) {} }
                            safPfds.clear()
                        }
                        runOnUiThread { result.success(null) }
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
                "startMigration" -> {
                    val oldPath = call.argument<String>("oldPath")
                    val newUriString = call.argument<String>("newUri")
                    if (oldPath == null || newUriString == null) {
                        result.error("INVALID_ARGS", "oldPath or newUri is null", null)
                        return@setMethodCallHandler
                    }
                    
                    val newUri = Uri.parse(newUriString)
                    val root = DocumentFile.fromTreeUri(this@MainActivity, newUri)
                    if (root == null) {
                        result.error("SAF_INVALID", "cannot resolve new SAF directory", null)
                        return@setMethodCallHandler
                    }

                    migrationJob?.cancel()
                    
                    migrationJob = CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val oldDir = File(oldPath)
                            if (!oldDir.exists() || !oldDir.isDirectory) {
                                withContext(Dispatchers.Main) { result.error("INVALID_PATH", "oldPath is not a valid directory", null) }
                                return@launch
                            }
                            
                            val files = oldDir.listFiles() ?: emptyArray()
                            val totalBytes = files.sumOf { it.length() }.toDouble()
                            var bytesCopied = 0.0

                            for (file in files) {
                                ensureActive()
                                if (file.isDirectory) continue
                                
                                val fileName = file.name
                                val mimeType = getMimeTypeFromExtension(fileName)
                                var newFile = root.findFile(fileName)
                                if (newFile == null) {
                                    newFile = root.createFile(mimeType, fileName)
                                }
                                
                                if (newFile == null) {
                                    throw Exception("Could not create file $fileName in SAF directory")
                                }
                                
                                val os = contentResolver.openOutputStream(newFile.uri) ?: throw Exception("Failed to open SAF output stream")
                                os.use { outStream ->
                                    FileInputStream(file).use { inputStream ->
                                        val buffer = ByteArray(8 * 1024)
                                        var bytes = inputStream.read(buffer)
                                        while (bytes >= 0) {
                                            ensureActive()
                                            outStream.write(buffer, 0, bytes)
                                            bytesCopied += bytes
                                            
                                            if (totalBytes > 0) {
                                                val progress = (bytesCopied / totalBytes) * 100
                                                withContext(Dispatchers.Main) {
                                                    progressSink?.success(progress)
                                                }
                                            }
                                            
                                            bytes = inputStream.read(buffer)
                                        }
                                    }
                                }
                            }
                            
                            for (file in files) {
                                file.delete()
                            }
                            oldDir.delete()
                            
                            withContext(Dispatchers.Main) {
                                progressSink?.success(100.0)
                                result.success(true)
                            }
                        } catch (e: CancellationException) {
                            val files = File(oldPath).listFiles() ?: emptyArray()
                            for (file in files) {
                                root.findFile(file.name)?.delete()
                            }
                            throw e
                        } catch (e: Exception) {
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
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
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

    private fun getMimeTypeFromExtension(fileName: String): String {
        val extension = android.webkit.MimeTypeMap.getFileExtensionFromUrl(fileName)
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
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
