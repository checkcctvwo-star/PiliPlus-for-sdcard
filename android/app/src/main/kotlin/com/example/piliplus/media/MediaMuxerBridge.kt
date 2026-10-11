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
     * Merges video and audio streams using FFmpegKit.
     *
     * @param videoPath Path to input video file
     * @param audioPath Path to input audio file
     * @param outputPath Desired final output path
     * @param transcodeAudioToAac Whether to transcode audio stream to AAC 192k
     * @return Result<String> containing the output path on success, or an exception on failure
     */
    suspend fun mergeDash(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        transcodeAudioToAac: Boolean = false
    ): Result<String> = withContext(Dispatchers.IO) {
        val tempOutputPath = "$outputPath.muxing.tmp"
        val tempFile = File(tempOutputPath)
        val videoFile = File(videoPath)
        val audioFile = File(audioPath)
        val outputFile = File(outputPath)

        if (!videoFile.exists()) {
            return@withContext Result.failure(IllegalArgumentException("Video file does not exist: $videoPath"))
        }
        if (!audioFile.exists()) {
            return@withContext Result.failure(IllegalArgumentException("Audio file does not exist: $audioPath"))
        }

        // Ensure target directory exists
        outputFile.parentFile?.mkdirs()

        // Clean up previous incomplete temp file
        if (tempFile.exists()) {
            tempFile.delete()
        }

        try {
            val cmdList = mutableListOf(
                "-hide_banner",
                "-nostats",
                "-loglevel", "warning",
                "-y",
                "-i", videoPath,
                "-i", audioPath,
                "-map", "0:v:0",
                "-map", "1:a:0"
            )

            if (transcodeAudioToAac) {
                cmdList.addAll(listOf("-c:v", "copy", "-c:a", "aac", "-b:a", "192k"))
            } else {
                cmdList.addAll(listOf("-c", "copy"))
            }

            cmdList.addAll(listOf("-shortest", "-strict", "unofficial", "-movflags", "+faststart", tempOutputPath))

            Log.d(TAG, "Starting FFmpeg merge command: ${cmdList.joinToString(" ")}")
            val session = FFmpegKit.executeWithArguments(cmdList.toTypedArray())
            val returnCode = session.returnCode

            if (ReturnCode.isSuccess(returnCode)) {
                if (!tempFile.exists() || tempFile.length() == 0L) {
                    tempFile.delete()
                    val errorMsg = "Muxing reported success but output temp file is missing or empty"
                    Log.e(TAG, errorMsg)
                    return@withContext Result.failure(IllegalStateException(errorMsg))
                }

                if (outputFile.exists()) {
                    outputFile.delete()
                }

                val renamed = tempFile.renameTo(outputFile)
                if (!renamed) {
                    try {
                        tempFile.copyTo(outputFile, overwrite = true)
                        tempFile.delete()
                    } catch (e: Exception) {
                        tempFile.delete()
                        val errorMsg = "Failed to rename/move temp file to final destination: ${e.message}"
                        Log.e(TAG, errorMsg, e)
                        return@withContext Result.failure(IllegalStateException(errorMsg, e))
                    }
                }

                // Delete original video and audio temporary files
                try {
                    videoFile.delete()
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to delete input video file: ${videoFile.path}", e)
                }
                try {
                    audioFile.delete()
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to delete input audio file: ${audioFile.path}", e)
                }

                Log.i(TAG, "FFmpeg muxing completed successfully: $outputPath")
                Result.success(outputPath)
            } else {
                val failStackTrace = session.failStackTrace
                val logs = session.allLogsAsString
                val errorMsg = "FFmpegKit execution failed with returnCode: $returnCode, logs: $logs, stack: $failStackTrace"
                Log.e(TAG, errorMsg)
                if (tempFile.exists()) {
                    tempFile.delete()
                }
                Result.failure(RuntimeException(errorMsg))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error during mergeDash", e)
            if (tempFile.exists()) {
                tempFile.delete()
            }
            Result.failure(e)
        }
    }
}
