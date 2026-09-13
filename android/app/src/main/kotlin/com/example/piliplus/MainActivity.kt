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
import com.arialyy.aria.core.Aria
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileInputStream

enum class StoragePreference {
    Internal, SDCard, CustomSAF
}

class MainActivity : AudioServiceActivity() {
    private val REQUEST_CODE_OPEN_DOCUMENT_TREE = 42
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val safExecutor = java.util.concurrent.Executors.newFixedThreadPool(1)
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        Aria.download(this).register()
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
