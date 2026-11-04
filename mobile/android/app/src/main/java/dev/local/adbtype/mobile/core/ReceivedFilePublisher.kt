package dev.local.adbtype.mobile.core

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

/** 接收文件成功保存后的定位信息（写入聊天记录 / 用于打开分享）。 */
data class ReceivedFile(
    val fileName: String,
    /** 文件系统绝对路径（API 28 公共 Downloads / 旧消息）；MediaStore 场景为 null。 */
    val filePath: String?,
    /** 用户可访问的 content URI（API 29+ MediaStore）；API 28 为 null。 */
    val fileUri: String?,
    /** 给用户看的保存位置，例如「下载/文件互传助手」。 */
    val locationLabel: String,
)

/**
 * 收到文件后「保存到哪里」的抽象：
 * Android 29+ 用 MediaStore 公共 Download、API 28 用公共 Downloads 目录，
 * JVM 单元测试用临时目录（[DirectoryReceivedFilePublisher]）。
 */
interface ReceivedFilePublisher {

    /** 给用户看的保存位置，例如「下载/文件互传助手」。 */
    val locationLabel: String

    /**
     * 把 [input] 里的恰好 [size] 字节保存成 [rawName]（已通过 FileNames.sanitizeIncoming 校验）。
     * 成功返回定位信息；失败返回 null，实现方负责清理半截文件。
     */
    fun save(rawName: String, size: Long, input: InputStream, onProgress: (Long) -> Unit): ReceivedFile?
}

/**
 * 目录实现：直接写文件系统。
 *  - API 28：公共 Downloads/文件互传助手（需要 WRITE_EXTERNAL_STORAGE）；
 *  - 单元测试：临时目录。
 */
class DirectoryReceivedFilePublisher(
    private val directoryProvider: () -> File,
    override val locationLabel: String,
    private val chunkBytes: Int = LanProtocol.FILE_CHUNK_BYTES,
) : ReceivedFilePublisher {

    override fun save(
        rawName: String,
        size: Long,
        input: InputStream,
        onProgress: (Long) -> Unit,
    ): ReceivedFile? {
        if (size < 0L) return null
        val directory = directoryProvider()
        if (!directory.exists() && !directory.mkdirs()) return null
        val target = FileNames.uniqueFile(directory, rawName)
        var written = 0L
        try {
            FileOutputStream(target).use { output ->
                val buffer = ByteArray(minOf(chunkBytes.coerceIn(1, LanProtocol.FILE_CHUNK_BYTES), LanProtocol.FILE_CHUNK_BYTES))
                while (written < size) {
                    val want = minOf(buffer.size.toLong(), size - written).toInt()
                    val read = input.read(buffer, 0, want)
                    if (read < 0) throw IOException("连接中断")
                    output.write(buffer, 0, read)
                    written += read
                    onProgress(written)
                }
                output.flush()
            }
            return ReceivedFile(
                fileName = target.name,
                filePath = target.absolutePath,
                fileUri = null,
                locationLabel = locationLabel,
            )
        } catch (e: Exception) {
            target.delete()
            return null
        }
    }
}
