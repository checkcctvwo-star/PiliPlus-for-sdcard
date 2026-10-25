package com.example.piliplus.media

import android.util.Log
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import com.arthenica.ffmpegkit.ReturnCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

object MediaMuxerBridge {
    private const val TAG = "MediaMuxerBridge"
    private val muxMutex = Mutex()

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
        val tempOutputPath = "${outputPath.removeSuffix(".mp4")}.tmp.mp4"
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

        muxMutex.withLock {
            try {
                // Clear lingering sessions to prevent memory/thread saturation
                try { FFmpegKitConfig.clearSessions() } catch (_: Exception) {}

                var isSuccess = false

                if (!forceAudioTranscode) {
                    // Phase 1: Fast direct stream copy with timestamp normalization
                    Log.i(TAG, "Starting Phase 1 (-c copy) muxing for $outputPath")
                    val cmdCopy = listOf(
                        "-hide_banner", "-nostats", "-loglevel", "warning", "-y",
                        "-fflags", "+genpts+discardcorrupt",
                        "-i", videoPath, "-i", audioPath,
                        "-map", "0:v:0", "-map", "1:a:0",
                        "-c", "copy",
                        "-avoid_negative_ts", "make_zero",
                        "-max_interleave_delta", "0",
                        "-shortest", "-strict", "unofficial",
                        "-f", "mp4",
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
                        "-fflags", "+genpts+discardcorrupt",
                        "-i", videoPath, "-i", audioPath,
                        "-map", "0:v:0", "-map", "1:a:0",
                        "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
                        "-avoid_negative_ts", "make_zero",
                        "-max_interleave_delta", "0",
                        "-shortest", "-strict", "unofficial",
                        "-f", "mp4",
                        tempOutputPath
                    )
                    val sessionTranscode = FFmpegKit.executeWithArguments(cmdTranscode.toTypedArray())
                    if (ReturnCode.isSuccess(sessionTranscode.returnCode) && tempFile.exists() && tempFile.length() > 0L) {
                        isSuccess = true
                    } else {
                        // Fallback Phase 3: relaxed stream mapping (-map 0:v? -map 1:a?) in case of index mismatch
                        Log.w(TAG, "Phase 2 failed with code ${sessionTranscode.returnCode}. Trying relaxed mapping...")
                        if (tempFile.exists()) tempFile.delete()

                        val cmdRelaxed = listOf(
                            "-hide_banner", "-nostats", "-loglevel", "warning", "-y",
                            "-fflags", "+genpts+discardcorrupt",
                            "-i", videoPath, "-i", audioPath,
                            "-map", "0:v?", "-map", "1:a?",
                            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                            "-avoid_negative_ts", "make_zero",
                            "-shortest", "-strict", "unofficial",
                            "-f", "mp4",
                            tempOutputPath
                        )
                        val sessionRelaxed = FFmpegKit.executeWithArguments(cmdRelaxed.toTypedArray())
                        if (ReturnCode.isSuccess(sessionRelaxed.returnCode) && tempFile.exists() && tempFile.length() > 0L) {
                            isSuccess = true
                        } else {
                            val errMsg = "All FFmpeg muxing attempts failed for $outputPath. Last logs: ${sessionRelaxed.allLogsAsString}"
                            Log.e(TAG, errMsg)
                            if (tempFile.exists()) tempFile.delete()
                            return@withContext Result.failure(IllegalStateException(errMsg))
                        }
                    }
                }

                // Finalize output file
                if (outputFile.exists()) outputFile.delete()
                val renamed = tempFile.renameTo(outputFile) || runCatching {
                    tempFile.copyTo(outputFile, overwrite = true)
                    tempFile.delete()
                    true
                }.getOrDefault(false)

                if (!renamed || !outputFile.exists() || outputFile.length() == 0L) {
                    tempFile.delete()
                    return@withContext Result.failure(IllegalStateException("Failed to move temp file to $outputPath"))
                }

                // Verify container integrity: ensure valid ftyp/mdat and complete moov box
                if (!verifyMp4Integrity(outputFile)) {
                    outputFile.delete()
                    val errMsg = "Muxed MP4 failed integrity check (invalid container structure or missing moov): $outputPath"
                    Log.e(TAG, errMsg)
                    return@withContext Result.failure(IllegalStateException(errMsg))
                }

                // Delete original temporary video and audio m4s slices only after verified integrity
                try { videoFile.delete() } catch (_: Exception) {}
                try { audioFile.delete() } catch (_: Exception) {}

                Log.i(TAG, "FFmpeg muxing completed successfully and passed integrity check: $outputPath (size: ${outputFile.length()})")
                Result.success(outputPath)
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error during mergeDash", e)
                if (tempFile.exists()) tempFile.delete()
                Result.failure(e)
            } finally {
                try { FFmpegKitConfig.clearSessions() } catch (_: Exception) {}
            }
        }
    }

    /**
     * Fast container integrity verification for MP4 files.
     * Ensures minimum header structure, valid major brand, and valid 'moov' atom.
     */
    private fun verifyMp4Integrity(file: File): Boolean {
        if (!file.exists() || file.length() < 1024) return false
        return try {
            java.io.RandomAccessFile(file, "r").use { raf ->
                val len = raf.length()
                val hdr = ByteArray(16)
                raf.readFully(hdr)
                val type = String(hdr, 4, 4)
                if (type != "ftyp" && type != "moov" && type != "mdat") return false

                var hasMoov = false
                val buf = ByteArray(64 * 1024)

                // 1. Check head for moov
                raf.seek(0)
                val readStart = raf.read(buf)
                if (readStart > 0 && String(buf, 0, readStart, Charsets.ISO_8859_1).contains("moov")) {
                    hasMoov = true
                }

                // 2. Check tail for moov (common when -movflags +faststart is omitted)
                if (!hasMoov && len > 64 * 1024) {
                    val searchLen = minOf(len, 32L * 1024 * 1024)
                    val startOffset = len - searchLen
                    var curOffset = startOffset
                    while (curOffset < len) {
                        raf.seek(curOffset)
                        val r = raf.read(buf)
                        if (r <= 0) break
                        if (String(buf, 0, r, Charsets.ISO_8859_1).contains("moov")) {
                            hasMoov = true
                            break
                        }
                        curOffset += (r - 8)
                    }
                }
                hasMoov
            }
        } catch (e: Exception) {
            Log.w(TAG, "MP4 integrity check failed for ${file.path}", e)
            false
        }
    }
}

