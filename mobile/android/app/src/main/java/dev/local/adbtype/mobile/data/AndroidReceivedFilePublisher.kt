package dev.local.adbtype.mobile.data

import android.Manifest
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import dev.local.adbtype.mobile.core.DirectoryReceivedFilePublisher
import dev.local.adbtype.mobile.core.FileNames
import dev.local.adbtype.mobile.core.LanProtocol
import dev.local.adbtype.mobile.core.ReceivedFile
import dev.local.adbtype.mobile.core.ReceivedFilePublisher
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Locale

/**
 * 把收到的文件保存到用户能在「文件管理 / 下载」里直接看到的公共目录：
 *
 *  - API 29+：MediaStore.Downloads，RELATIVE_PATH = Download/文件互传助手/，
 *    以 IS_PENDING=1 写入，完成后置 0；消息里保存 content URI。
 *  - API 28：公共 Downloads/文件互传助手 目录 + WRITE_EXTERNAL_STORAGE 运行时权限；
 *    消息里保存文件路径，打开/分享走 FileProvider。
 *  - API 28 未授予存储权限时退回 App 专属目录（不会让传输直接失败），并在界面上说明。
 */
class AndroidReceivedFilePublisher(private val context: Context) : ReceivedFilePublisher {

    override val locationLabel: String
        get() = if (usesMediaStore() || hasLegacyWritePermission()) PUBLIC_LABEL else PRIVATE_LABEL

    override fun save(
        rawName: String,
        size: Long,
        input: InputStream,
        onProgress: (Long) -> Unit,
    ): ReceivedFile? {
        if (size < 0L) return null
        return if (usesMediaStore()) {
            saveViaMediaStore(rawName, size, input, onProgress)
        } else {
            saveViaFiles(rawName, size, input, onProgress)
        }
    }

    private fun usesMediaStore(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun hasLegacyWritePermission(): Boolean {
        val permission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        )
        return permission == PackageManager.PERMISSION_GRANTED
    }

    private fun saveViaMediaStore(
        rawName: String,
        size: Long,
        input: InputStream,
        onProgress: (Long) -> Unit,
    ): ReceivedFile? {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val displayName = uniqueDisplayName(resolver, collection, rawName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeTypeFor(displayName))
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri: Uri = try {
            resolver.insert(collection, values)
        } catch (e: Exception) {
            null
        } ?: return null

        return try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("无法写入公共下载目录")
            output.use { stream ->
                val buffer = ByteArray(CHUNK_BYTES)
                var written = 0L
                while (written < size) {
                    val want = minOf(buffer.size.toLong(), size - written).toInt()
                    val read = input.read(buffer, 0, want)
                    if (read < 0) throw IOException("连接中断")
                    stream.write(buffer, 0, read)
                    written += read
                    onProgress(written)
                }
                stream.flush()
            }
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            try {
                resolver.update(uri, done, null, null)
            } catch (e: Exception) {
                // update 失败也不影响文件已经写入；MediaStore 会按自己的规则处理
            }
            ReceivedFile(
                fileName = displayName,
                filePath = null,
                fileUri = uri.toString(),
                locationLabel = PUBLIC_LABEL,
            )
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (ignored: Exception) {
                // 清理失败只能这样
            }
            null
        }
    }

    private fun saveViaFiles(
        rawName: String,
        size: Long,
        input: InputStream,
        onProgress: (Long) -> Unit,
    ): ReceivedFile? {
        val writablePublic = hasLegacyWritePermission()
        val directory = if (writablePublic) {
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), SUB_DIRECTORY)
        } else {
            context.getExternalFilesDir(RECEIVED_FALLBACK_DIR) ?: File(context.filesDir, RECEIVED_FALLBACK_DIR)
        }
        val label = if (writablePublic) PUBLIC_LABEL else PRIVATE_LABEL
        return DirectoryReceivedFilePublisher({ directory }, label, CHUNK_BYTES)
            .save(rawName, size, input, onProgress)
    }

    /**
     * 在公共下载目录里找一个不重名的显示名：
     * 先查 MediaStore 里同目录的 DISPLAY_NAME，再补上公共目录里实际存在的文件名。
     */
    private fun uniqueDisplayName(resolver: ContentResolver, collection: Uri, rawName: String): String {
        val existing = LinkedHashSet<String>()
        try {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                MediaStore.MediaColumns.RELATIVE_PATH + "=?",
                arrayOf(RELATIVE_PATH),
                null,
            )?.use { cursor ->
                val index = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                if (index >= 0) {
                    while (cursor.moveToNext()) {
                        val name = cursor.getString(index)
                        if (!name.isNullOrBlank()) existing.add(name)
                    }
                }
            }
        } catch (e: Exception) {
            // 查询失败时按空集合处理，至少不会因为查询异常中断保存
        }
        try {
            publicDownloadDirectory()?.list()?.forEach { existing.add(it) }
        } catch (e: Exception) {
            // 读不到目录列表也不影响 MediaStore 查询结果
        }
        return FileNames.uniqueName(existing, rawName)
    }

    private fun publicDownloadDirectory(): File? {
        return try {
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), SUB_DIRECTORY)
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        /** 公共下载目录下的子目录名。 */
        const val SUB_DIRECTORY = "文件互传助手"

        /** MediaStore 的 RELATIVE_PATH（下载根目录下的子目录）。 */
        const val RELATIVE_PATH = "Download/文件互传助手/"

        /** 给用户看的保存位置。 */
        const val PUBLIC_LABEL = "下载/文件互传助手"

        /** API 28 未授予存储权限时的兜底位置。 */
        const val PRIVATE_LABEL = "应用专属目录（未授予存储权限）"

        private const val RECEIVED_FALLBACK_DIR = "received"
        private const val CHUNK_BYTES = LanProtocol.FILE_CHUNK_BYTES

        fun mimeTypeFor(fileName: String): String {
            val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
            if (extension.isEmpty()) return "application/octet-stream"
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"
        }
    }
}
