package dev.local.adbtype.mobile.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * TCP 帧编解码：4 字节大端长度 + UTF-8 JSON 正文。
 * 协议见 docs/LAN-transfer-spec.md §3。
 */
object LanFrame {

    const val HEADER_BYTES = 4

    /** 单帧正文上限 16 MiB，超出视为协议错误。 */
    const val MAX_BODY_BYTES = 16 * 1024 * 1024

    /** 文件内容按 256 KiB 一块收发。 */
    const val FILE_CHUNK_BYTES = 256 * 1024

    /** 把「长度头 + 正文」拼成一个完整帧。 */
    fun encodeBody(body: ByteArray): ByteArray {
        if (body.size > MAX_BODY_BYTES) throw LanJsonException("帧正文超过 16 MiB 上限")
        val frame = ByteArray(HEADER_BYTES + body.size)
        val length = body.size
        frame[0] = ((length ushr 24) and 0xFF).toByte()
        frame[1] = ((length ushr 16) and 0xFF).toByte()
        frame[2] = ((length ushr 8) and 0xFF).toByte()
        frame[3] = (length and 0xFF).toByte()
        System.arraycopy(body, 0, frame, HEADER_BYTES, body.size)
        return frame
    }

    fun encodeFrame(message: Map<String, Any?>): ByteArray =
        encodeBody(LanJson.stringify(message).toByteArray(Charsets.UTF_8))

    fun encodeRawJson(json: String): ByteArray =
        encodeBody(json.toByteArray(Charsets.UTF_8))

    /** 解析 4 字节长度头；长度非法（<=0 或 > 16 MiB）时返回 null。 */
    fun headerLength(header: ByteArray): Int? {
        if (header.size < HEADER_BYTES) return null
        val length = ((header[0].toInt() and 0xFF) shl 24) or
            ((header[1].toInt() and 0xFF) shl 16) or
            ((header[2].toInt() and 0xFF) shl 8) or
            (header[3].toInt() and 0xFF)
        if (length <= 0 || length > MAX_BODY_BYTES) return null
        return length
    }

    fun decodeBody(body: ByteArray): Map<String, Any?>? {
        val text = String(body, Charsets.UTF_8)
        return LanJson.parseOrNull(text)?.asJsonObject()
    }

    /** 循环读满 count 个字节；EOF / 读超时 / IO 异常都返回 null。 */
    fun readFully(input: InputStream, count: Int): ByteArray? {
        if (count < 0) return null
        if (count == 0) return ByteArray(0)
        val buffer = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = try {
                input.read(buffer, offset, count - offset)
            } catch (e: IOException) {
                return null
            }
            if (read <= 0) return null
            offset += read
        }
        return buffer
    }

    /** 读一帧 JSON；读不到 / 帧非法都返回 null（调用方按连接错误处理）。 */
    fun readFrame(input: InputStream): Map<String, Any?>? {
        val header = readFully(input, HEADER_BYTES) ?: return null
        val length = headerLength(header) ?: return null
        val body = readFully(input, length) ?: return null
        return decodeBody(body)
    }

    /** 写一帧 JSON；失败返回 false（连接已断、磁盘/网络 IO 异常等）。 */
    fun writeFrame(output: OutputStream, message: Map<String, Any?>): Boolean {
        val frame = try {
            encodeFrame(message)
        } catch (e: Exception) {
            return false
        }
        return try {
            output.write(frame)
            output.flush()
            true
        } catch (e: IOException) {
            false
        }
    }

    /**
     * 从输入流精确拷贝 totalBytes 个字节到输出流（文件内容不套 JSON 帧）。
     * 每写完一块回调一次进度；失败返回 false，调用方负责删掉半截文件。
     */
    fun copyExact(
        input: InputStream,
        output: OutputStream,
        totalBytes: Long,
        chunkBytes: Int = FILE_CHUNK_BYTES,
        onProgress: ((Long) -> Unit)? = null,
    ): Boolean {
        if (totalBytes < 0) return false
        if (totalBytes == 0L) return true
        val bufferSize = minOf(chunkBytes.toLong(), maxOf(totalBytes, 1L)).toInt().coerceAtLeast(1)
        val buffer = ByteArray(bufferSize)
        var remaining = totalBytes
        while (remaining > 0) {
            val want = minOf(buffer.size.toLong(), remaining).toInt()
            val read = try {
                input.read(buffer, 0, want)
            } catch (e: IOException) {
                return false
            }
            if (read <= 0) return false
            try {
                output.write(buffer, 0, read)
            } catch (e: IOException) {
                return false
            }
            remaining -= read
            onProgress?.invoke(totalBytes - remaining)
        }
        return true
    }
}
