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
                "resumeAll" -> {
                    Aria.download(this).resumeAllTask()
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
