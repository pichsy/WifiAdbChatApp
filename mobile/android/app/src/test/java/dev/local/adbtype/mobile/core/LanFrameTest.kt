package dev.local.adbtype.mobile.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanFrameTest {

    @Test
    fun encodesBigEndianLengthHeader() {
        val body = "{\"type\":\"ok\"}".toByteArray(Charsets.UTF_8)
        val frame = LanFrame.encodeBody(body)
        assertEquals(body.size + 4, frame.size)
        val expected = byteArrayOf(
            ((body.size ushr 24) and 0xFF).toByte(),
            ((body.size ushr 16) and 0xFF).toByte(),
            ((body.size ushr 8) and 0xFF).toByte(),
            (body.size and 0xFF).toByte(),
        )
        assertArrayEquals(expected, frame.copyOfRange(0, 4))
        assertArrayEquals(body, frame.copyOfRange(4, frame.size))
    }

    @Test
    fun roundTripsJsonFrameThroughStreams() {
        val output = ByteArrayOutputStream()
        val message = LanProtocol.text("中文 😀")
        assertTrue(LanFrame.writeFrame(output, message))

        val input = ByteArrayInputStream(output.toByteArray())
        val decoded = LanFrame.readFrame(input)
        assertEquals("text", decoded?.stringValue("type"))
        assertEquals("中文 😀", decoded?.stringValue("text"))
    }

    @Test
    fun readsFrameWhenStreamReturnsOneByteAtATime() {
        val output = ByteArrayOutputStream()
        LanFrame.writeFrame(output, LanProtocol.hello("device-1", "手机", null))
        val trickle = TrickleInputStream(output.toByteArray())
        val decoded = LanFrame.readFrame(trickle)
        assertEquals("ADBTypeLink", decoded?.stringValue("app"))
        assertEquals("device-1", decoded?.stringValue("id"))
    }

    @Test
    fun rejectsZeroAndOversizedLengths() {
        assertNull(LanFrame.headerLength(byteArrayOf(0, 0, 0, 0)))
        // 只构造 4 字节长度头，验证超过 16 MiB 的帧被拒（不真的分配 16 MiB 正文）
        val oversize = LanFrame.MAX_BODY_BYTES + 1
        val oversizeHeader = byteArrayOf(
            ((oversize ushr 24) and 0xFF).toByte(),
            ((oversize ushr 16) and 0xFF).toByte(),
            ((oversize ushr 8) and 0xFF).toByte(),
            (oversize and 0xFF).toByte(),
        )
        assertEquals(4, oversizeHeader.size)
        assertNull(LanFrame.headerLength(oversizeHeader))
        assertNull(LanFrame.readFrame(ByteArrayInputStream(oversizeHeader)))
    }

    @Test
    fun truncatedFrameReturnsNull() {
        val output = ByteArrayOutputStream()
        LanFrame.writeFrame(output, LanProtocol.ok())
        val bytes = output.toByteArray()
        val truncated = ByteArrayInputStream(bytes.copyOfRange(0, bytes.size - 1))
        assertNull(LanFrame.readFrame(truncated))
    }

    @Test
    fun copyExactTransfersAllBytesAndReportsProgress() {
        val source = ByteArray(700_000) { (it % 251).toByte() }
        val progress = mutableListOf<Long>()
        val output = ByteArrayOutputStream()
        val ok = LanFrame.copyExact(ByteArrayInputStream(source), output, source.size.toLong()) { progress.add(it) }
        assertTrue(ok)
        assertArrayEquals(source, output.toByteArray())
        assertEquals(source.size.toLong(), progress.last())
        assertTrue(progress.size >= 2)
    }

    @Test
    fun copyExactFailsWhenSourceIsShort() {
        val output = ByteArrayOutputStream()
        assertFalse(LanFrame.copyExact(ByteArrayInputStream(ByteArray(10)), output, 100))
    }

    @Test
    fun refusesToEncodeFrameOverLimit() {
        try {
            LanFrame.encodeBody(ByteArray(LanFrame.MAX_BODY_BYTES + 1))
            throw AssertionError("应当拒绝超过 16 MiB 的帧")
        } catch (expected: LanJsonException) {
            assertEquals("帧正文超过 16 MiB 上限", expected.message)
        }
    }

    private class TrickleInputStream(private val bytes: ByteArray) : InputStream() {
        private var position = 0

        override fun read(): Int {
            if (position >= bytes.size) return -1
            return bytes[position++].toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (position >= bytes.size) return -1
            val count = minOf(1, len)
            b[off] = bytes[position++]
            return count
        }
    }
}
