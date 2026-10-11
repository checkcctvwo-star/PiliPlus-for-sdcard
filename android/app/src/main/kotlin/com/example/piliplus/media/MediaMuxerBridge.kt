package com.example.piliplus.media

import android.util.Log
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.ReturnCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

object MediaMuxerBridge {
    private const val TAG = "MediaMuxerBridge"

    /**
     * Merges DASH video and audio streams using FFmpegKit.
     * Incorporates adaptive fallback:
     * Attempts fast direct copy first (-c copy). If it fails (e.g. FLAC / Dolby / codec incompatible with MP4 container),
     * automatically falls back to re-encoding audio to AAC 192k (-c:v copy -c:a aac -b:a 192k) to ensure 100% success.
     */
    suspend fun mergeDash(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        forceAudioTranscode: Boolean = false
    ): Result<String> = withContext(Dispatchers.IO) {
        val tempOutputPath = "$outputPath.muxing.tmp"
        val tempFile = File(tempOutputPath)
        val videoFile = File(videoPath)
        val audioFile = File(audioPath)
        val outputFile = File(outputPath)

        if (!videoFile.exists() || videoFile.length() == 0L) {
            return@withContext Result.failure(IllegalArgumentException("Video file missing or empty: $videoPath"))
        }
        if (!audioFile.exists() || audioFile.length() == 0L) {
            return@withContext Result.failure(IllegalArgumentException("Audio file missing or empty: $audioPath"))
        }

        outputFile.parentFile?.mkdirs()
        if (tempFile.exists()) tempFile.delete()

        try {
            var isSuccess = false

            if (!forceAudioTranscode) {
                // Phase 1: Fast direct stream copy
                Log.i(TAG, "Starting Phase 1 (-c copy) muxing for $outputPath")
                val cmdCopy = listOf(
                    "-hide_banner", "-nostats", "-loglevel", "warning", "-y",
                    "-i", videoPath, "-i", audioPath,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c", "copy",
                    "-shortest", "-strict", "unofficial", "-movflags", "+faststart",
                    tempOutputPath
                )
                val sessionCopy = FFmpegKit.executeWithArguments(cmdCopy.toTypedArray())
                if (ReturnCode.isSuccess(sessionCopy.returnCode) && tempFile.exists() && tempFile.length() > 0L) {
                    isSuccess = true
                } else {
                    Log.w(TAG, "Phase 1 (-c copy) failed with code ${sessionCopy.returnCode}. Logs: ${sessionCopy.allLogsAsString}. Falling back to Phase 2 (AAC)...")
                    if (tempFile.exists()) tempFile.delete()
                }
            }

            if (!isSuccess) {
                // Phase 2: Transcode audio to AAC (handles FLAC/Dolby/E-AC3 incompatible audio)
                Log.i(TAG, "Starting Phase 2 (AAC transcode) muxing for $outputPath")
                val cmdTranscode = listOf(
                    "-hide_banner", "-nostats", "-loglevel", "warning", "-y",
                    "-i", videoPath, "-i", audioPath,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
                    "-shortest", "-strict", "unofficial", "-movflags", "+faststart",
                    tempOutputPath
                )
                val sessionTranscode = FFmpegKit.executeWithArguments(cmdTranscode.toTypedArray())
                if (ReturnCode.isSuccess(sessionTranscode.returnCode) && tempFile.exists() && tempFile.length() > 0L) {
                    isSuccess = true
                } else {
                    val errMsg = "Phase 2 (AAC transcode) also failed with code ${sessionTranscode.returnCode}. Logs: ${sessionTranscode.allLogsAsString}"
                    Log.e(TAG, errMsg)
                    if (tempFile.exists()) tempFile.delete()
                    return@withContext Result.failure(IllegalStateException(errMsg))
                }
            }

            // Finalize output file
            if (outputFile.exists()) outputFile.delete()
            val renamed = tempFile.renameTo(outputFile) || runCatching {
                tempFile.copyTo(outputFile, overwrite = true)
                tempFile.delete()
                true
            }.getOrDefault(false)

            if (!renamed) {
                tempFile.delete()
                return@withContext Result.failure(IllegalStateException("Failed to move temp file to $outputPath"))
            }

            // Delete original temporary video and audio m4s slices
            try { videoFile.delete() } catch (_: Exception) {}
            try { audioFile.delete() } catch (_: Exception) {}

            Log.i(TAG, "FFmpeg muxing completed successfully: $outputPath (size: ${outputFile.length()})")
            Result.success(outputPath)
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error during mergeDash", e)
            if (tempFile.exists()) tempFile.delete()
            Result.failure(e)
        }
    }
}
