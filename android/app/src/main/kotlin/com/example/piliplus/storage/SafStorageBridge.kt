package com.example.piliplus.storage

import android.content.Context
import android.net.Uri
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.IOException

object SafStorageBridge {
    private const val TAG = "SafStorageBridge"

    /**
     * Atomically commits a local staging file to the target SAF DocumentFile directory.
     * E.g. commits staging "0.mp4" into treeUri / "12345/c_6789" / "0.mp4"
     */
    suspend fun commitFileToSaf(
        context: Context,
        srcFilePath: String,
        treeUriString: String,
        relativeSubDirPath: String,
        fileName: String
    ): Result<String> = withContext(Dispatchers.IO) {
        val srcFile = File(srcFilePath)
        if (!srcFile.exists() || srcFile.length() == 0L) {
            return@withContext Result.failure(IOException("Source file missing or empty: $srcFilePath"))
        }

        val root = DocumentFile.fromTreeUri(context, Uri.parse(treeUriString))
            ?: return@withContext Result.failure(IOException("Cannot resolve SAF Tree Uri: $treeUriString"))

        var targetDir = root
        if (relativeSubDirPath.isNotEmpty()) {
            for (segment in relativeSubDirPath.split("/").filter { it.isNotEmpty() }) {
                val next = targetDir.findFile(segment)
                targetDir = if (next != null && next.isDirectory) {
                    next
                } else {
                    targetDir.createDirectory(segment)
                        ?: return@withContext Result.failure(IOException("Failed to create SAF directory: $segment"))
                }
            }
        }

        val ext = fileName.substringAfterLast('.', "")
        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val tmpName = ".$fileName.tmp"

        val tmpDoc = targetDir.findFile(tmpName) ?: targetDir.createFile(mimeType, tmpName)
            ?: return@withContext Result.failure(IOException("Failed to create SAF placeholder for $tmpName"))

        try {
            val outStream = context.contentResolver.openOutputStream(tmpDoc.uri)
                ?: return@withContext Result.failure(IOException("Failed to open SAF output stream"))

            outStream.use { os ->
                FileInputStream(srcFile).use { input ->
                    input.copyTo(os, bufferSize = 256 * 1024)
                    os.flush()
                }
            }

            // Remove previous file if exists and atomically rename
            targetDir.findFile(fileName)?.delete()
            if (!tmpDoc.renameTo(fileName)) {
                return@withContext Result.failure(IOException("Failed to rename SAF tmp file to $fileName"))
            }

            // Cleanup local staging file
            srcFile.delete()
            Log.i(TAG, "Successfully committed $fileName to SAF: ${tmpDoc.uri}")
            Result.success(tmpDoc.uri.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Error committing $fileName to SAF", e)
            try { tmpDoc.delete() } catch (_: Exception) {}
            Result.failure(e)
        }
    }

    /**
     * Recursively scans a SAF Tree for entry.json and MP4 media files.
     * Returns a structured list of maps containing JSON content, relative directories, and file URIs.
     */
    suspend fun scanEntriesFromSaf(
        context: Context,
        treeUriString: String
    ): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        val root = DocumentFile.fromTreeUri(context, Uri.parse(treeUriString)) ?: return@withContext emptyList()
        val entryList = mutableListOf<Map<String, Any?>>()

        try {
            // First level: avid, s_seasonId, etc.
            val pageDirs = root.listFiles().filter { it.isDirectory }
            for (pageDir in pageDirs) {
                val pageDirName = pageDir.name ?: continue
                // Second level: c_cid, epId, etc.
                val entryDirs = pageDir.listFiles().filter { it.isDirectory }
                for (entryDir in entryDirs) {
                    val entryDirName = entryDir.name ?: continue
                    val entryFile = entryDir.findFile("entry.json")

                    if (entryFile != null && entryFile.isFile) {
                        try {
                            context.contentResolver.openInputStream(entryFile.uri)?.use { stream ->
                                val jsonStr = stream.bufferedReader().use { it.readText() }
                                entryList.add(
                                    mapOf(
                                        "json" to jsonStr,
                                        "pageDirName" to pageDirName,
                                        "entryDirName" to entryDirName,
                                        "entryFileUri" to entryFile.uri.toString(),
                                        "entryDirUri" to entryDir.uri.toString(),
                                        "pageDirUri" to pageDir.uri.toString()
                                    )
                                )
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to read entry.json in SAF $entryDirName", e)
                        }
                    } else {
                        // Check if 0.mp4 exists in entryDir or typeTag subdirectories
                        var hasMp4 = entryDir.findFile("0.mp4") != null
                        if (!hasMp4) {
                            for (sub in entryDir.listFiles().filter { it.isDirectory }) {
                                if (sub.findFile("0.mp4") != null) {
                                    hasMp4 = true
                                    break
                                }
                            }
                        }
                        if (hasMp4) {
                            entryList.add(
                                mapOf(
                                    "json" to null,
                                    "pageDirName" to pageDirName,
                                    "entryDirName" to entryDirName,
                                    "entryFileUri" to null,
                                    "entryDirUri" to entryDir.uri.toString(),
                                    "pageDirUri" to pageDir.uri.toString()
                                )
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to scan SAF directory tree", e)
        }
        entryList
    }

    /**
     * Calculates total byte size of a SAF directory tree.
     */
    suspend fun calculateSafSize(
        context: Context,
        treeUriString: String
    ): Long = withContext(Dispatchers.IO) {
        val root = DocumentFile.fromTreeUri(context, Uri.parse(treeUriString)) ?: return@withContext 0L
        var total = 0L

        fun walk(dir: DocumentFile) {
            for (file in dir.listFiles()) {
                if (file.isDirectory) {
                    walk(file)
                } else {
                    total += file.length()
                }
            }
        }

        walk(root)
        total
    }
}
