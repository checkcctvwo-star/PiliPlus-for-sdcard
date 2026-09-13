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
import com.arialyy.annotations.Download
import com.arialyy.aria.core.task.DownloadTask

enum class StoragePreference {
    Internal, SDCard, CustomSAF
}

class MainActivity : AudioServiceActivity() {
    private val REQUEST_CODE_OPEN_DOCUMENT_TREE = 42
    private var pendingDirectoryResult: MethodChannel.Result? = null
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
                    val dirs = getExternalFilesDirs(null)
                    // The first element is primary external storage, the second (if exists) is SD card
                    if (dirs.size > 1 && dirs[1] != null) {
                        result.success(dirs[1].absolutePath)
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

    @Download.onTaskComplete
    fun onTaskComplete(task: DownloadTask) {
        val prefs = getSharedPreferences("download_prefs", Context.MODE_PRIVATE)
        val safUriString = prefs.getString("custom_saf_uri", null)
        if (safUriString != null) {
            Thread {
                try {
                    val safUri = Uri.parse(safUriString)
                    val documentFile = DocumentFile.fromTreeUri(this, safUri)
                    if (documentFile != null) {
                        val fileName = task.entity.fileName
                        val mimeType = getMimeTypeFromExtension(fileName)
                        val tmpFileName = "$fileName.tmp"
                        var newFile = documentFile.findFile(tmpFileName)
                        if (newFile == null) {
                            newFile = documentFile.createFile(mimeType, tmpFileName)
                        }
                        if (newFile != null) {
                            val newFileUri = newFile.uri
                            contentResolver.openOutputStream(newFileUri)?.use { os ->
                                FileInputStream(task.entity.filePath).use { inputStream ->
                                    inputStream.copyTo(os)
                                    os.flush()
                                }
                            }
                            newFile.renameTo(fileName)
                            val oldFile = File(task.entity.filePath)
                            if (oldFile.exists()) {
                                oldFile.delete()
                            }
                        }
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }.start()
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
