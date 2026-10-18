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
     * Commits a local staging file to the target SAF DocumentFile directory reliably.
     * E.g. commits staging "0.mp4" into treeUri / "12345/c_6789" / "0.mp4"
     * Directly overwrites target file to avoid external SD card FAT32/exFAT renameTo failures.
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

        // Use findFile or createFile with write-truncate ("wt") to prevent duplicate "(1)" files on external SD cards
        val targetDoc = targetDir.findFile(fileName)
            ?: targetDir.createFile(mimeType, fileName)
            ?: return@withContext Result.failure(IOException("Failed to create SAF document for $fileName"))

        try {
            val outStream = context.contentResolver.openOutputStream(targetDoc.uri, "wt")
                ?: context.contentResolver.openOutputStream(targetDoc.uri)
                ?: return@withContext Result.failure(IOException("Failed to open SAF output stream for ${targetDoc.uri}"))

            outStream.use { os ->
                FileInputStream(srcFile).use { input ->
                    input.copyTo(os, bufferSize = 256 * 1024)
                    os.flush()
                }
            }

            // Verify written size
            if (targetDoc.length() == 0L && srcFile.length() > 0L) {
                targetDoc.delete()
                return@withContext Result.failure(IOException("SAF file write resulted in 0 bytes for $fileName"))
            }

            // Cleanup local staging file
            srcFile.delete()
            Log.i(TAG, "Successfully committed $fileName to SAF: ${targetDoc.uri} (size: ${targetDoc.length()})")
            Result.success(targetDoc.uri.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Error committing $fileName to SAF", e)
            Result.failure(e)
        }
    }

    /**
     * Resolves SAF Tree / Document URI to a readable physical POSIX path if accessible.
     */
    fun resolveSafUriToPath(context: Context, uriString: String): String? {
        try {
            val uri = Uri.parse(uriString)
            val docId = when {
                android.provider.DocumentsContract.isDocumentUri(context, uri) ->
                    android.provider.DocumentsContract.getDocumentId(uri)
                android.provider.DocumentsContract.isTreeUri(uri) ->
                    android.provider.DocumentsContract.getTreeDocumentId(uri)
                else -> uri.lastPathSegment
            } ?: return null

            val parts = docId.split(":", limit = 2)
            if (parts.size < 2) return null
            val volume = parts[0]
            val relPath = parts[1]

            val candidatePath = if (volume.equals("primary", ignoreCase = true)) {
                "/storage/emulated/0/$relPath"
            } else {
                "/storage/$volume/$relPath"
            }

            val file = File(candidatePath)
            if (file.exists() && file.canRead()) {
                return file.absolutePath
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to resolve SAF URI to path: $uriString", e)
        }
        return null
    }

    /**
     * Opens an input file descriptor from SAF URI and detaches it.
     * Can be used as fdclose://$fd for libmpv.
     * Supports standard Document URIs and smart fallback for concatenated tree subpaths.
     */
    fun openSafFd(context: Context, uriString: String): Int? {
        return try {
            val uri = Uri.parse(uriString)
            val pfd = try {
                context.contentResolver.openFileDescriptor(uri, "r")
            } catch (e: Exception) {
                // If direct open fails, attempt smart resolution via tree contract or traversal
                Log.w(TAG, "Direct open failed, trying fallback resolution for: $uriString")
                findDocumentUriFallback(context, uriString)?.let { fallbackUri ->
                    context.contentResolver.openFileDescriptor(fallbackUri, "r")
                }
            }
            pfd?.detachFd()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open SAF FD for $uriString", e)
            null
        }
    }

    /**
     * Reads entire bytes of a SAF Document URI into memory.
     * Useful for reading small metadata files such as danmaku.pb.
     */
    fun readSafBytes(context: Context, uriString: String): ByteArray? {
        return try {
            val uri = Uri.parse(uriString)
            val inputStream = try {
                context.contentResolver.openInputStream(uri)
            } catch (e: Exception) {
                findDocumentUriFallback(context, uriString)?.let { fallbackUri ->
                    context.contentResolver.openInputStream(fallbackUri)
                }
            }
            inputStream?.use { it.readBytes() }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read SAF bytes for $uriString", e)
            null
        }
    }

    private fun findDocumentUriFallback(context: Context, rawUri: String): Uri? {
        return try {
            val parsed = Uri.parse(rawUri)
            val path = parsed.path ?: return null
            if (path.contains("/tree/")) {
                val treeId = android.provider.DocumentsContract.getTreeDocumentId(parsed)
                val baseTreeUri = android.provider.DocumentsContract.buildTreeDocumentUri(parsed.authority, treeId)
                val afterTree = rawUri.substringAfter(treeId, "").substringAfter("%3A", "").substringAfter(":", "")
                if (afterTree.isNotEmpty()) {
                    val relativeSegments = afterTree.trim('/').split('/').filter { it.isNotEmpty() }
                    if (relativeSegments.isNotEmpty()) {
                        // Strategy 1: Build document ID directly: "$treeId/$relPath"
                        val docId = "$treeId/${relativeSegments.joinToString("/")}"
                        val docUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(baseTreeUri, docId)
                        try {
                            context.contentResolver.openFileDescriptor(docUri, "r")?.close()
                            return docUri
                        } catch (_: Exception) {}

                        // Strategy 2: DocumentFile step-by-step traversal
                        var currentDir = DocumentFile.fromTreeUri(context, baseTreeUri)
                        for (i in 0 until relativeSegments.size - 1) {
                            currentDir = currentDir?.findFile(relativeSegments[i])
                        }
                        val leafFile = currentDir?.findFile(relativeSegments.last())
                        if (leafFile != null && leafFile.isFile) {
                            return leafFile.uri
                        }
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
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
                    val safFileUris = mutableMapOf<String, String>()

                    // Collect all files in entryDir and its subdirectories (such as 80/0.mp4)
                    fun collectUris(dir: DocumentFile, prefix: String = "") {
                        for (file in dir.listFiles()) {
                            val relName = if (prefix.isEmpty()) file.name.orEmpty() else "$prefix/${file.name}"
                            if (file.isFile) {
                                safFileUris[relName] = file.uri.toString()
                                val baseName = file.name.orEmpty()
                                if (baseName == "0.mp4") safFileUris["0.mp4"] = file.uri.toString()
                                if (baseName == "video.m4s") safFileUris["video.m4s"] = file.uri.toString()
                                if (baseName == "audio.m4s") safFileUris["audio.m4s"] = file.uri.toString()
                                if (baseName == "entry.json") safFileUris["entry.json"] = file.uri.toString()
                                if (baseName == "cover.jpg") safFileUris["cover.jpg"] = file.uri.toString()
                                if (baseName == "danmaku.pb") safFileUris["danmaku.pb"] = file.uri.toString()
                            } else if (file.isDirectory) {
                                collectUris(file, file.name.orEmpty())
                            }
                        }
                    }
                    collectUris(entryDir)

                    val entryFileUri = safFileUris["entry.json"]
                    var jsonStr: String? = null
                    if (entryFileUri != null) {
                        try {
                            context.contentResolver.openInputStream(Uri.parse(entryFileUri))?.use { stream ->
                                jsonStr = stream.bufferedReader().use { it.readText() }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to read entry.json in SAF $entryDirName", e)
                        }
                    }

                    if (jsonStr != null || safFileUris.containsKey("0.mp4") || safFileUris.containsKey("video.m4s")) {
                        entryList.add(
                            mapOf(
                                "json" to jsonStr,
                                "pageDirName" to pageDirName,
                                "entryDirName" to entryDirName,
                                "entryFileUri" to entryFileUri,
                                "entryDirUri" to entryDir.uri.toString(),
                                "pageDirUri" to pageDir.uri.toString(),
                                "safFileUris" to safFileUris
                            )
                        )
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
