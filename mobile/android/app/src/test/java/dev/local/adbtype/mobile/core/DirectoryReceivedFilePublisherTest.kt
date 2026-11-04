package dev.local.adbtype.mobile.core

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DirectoryReceivedFilePublisherTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun savesBytesAndReportsProgress() {
        val directory = File(temp.root, "Download/文件互传助手")
        val publisher = DirectoryReceivedFilePublisher({ directory }, "下载/文件互传助手")
        val payload = ByteArray(700_000) { (it % 251).toByte() }
        val progress = ArrayList<Long>()

        val saved = publisher.save("报告 v2.pdf", payload.size.toLong(), ByteArrayInputStream(payload)) {
            progress.add(it)
        }

        assertNotNull(saved)
        assertEquals("报告 v2.pdf", saved!!.fileName)
        assertEquals("下载/文件互传助手", saved.locationLabel)
        assertEquals(null, saved.fileUri)
        assertEquals(File(directory, "报告 v2.pdf").absolutePath, saved.filePath)
        assertEquals(payload.size.toLong(), progress.last())
        assertArrayEquals(payload, File(saved.filePath!!).readBytes())
    }

    @Test
    fun duplicateNamesGetNumbered() {
        val directory = File(temp.root, "Download/文件互传助手")
        val publisher = DirectoryReceivedFilePublisher({ directory }, "下载/文件互传助手")
        val first = publisher.save("同名.txt", 3, ByteArrayInputStream("aaa".toByteArray()), {})
        val second = publisher.save("同名.txt", 3, ByteArrayInputStream("bbb".toByteArray()), {})
        val third = publisher.save("同名.txt", 3, ByteArrayInputStream("ccc".toByteArray()), {})

        assertEquals("同名.txt", first?.fileName)
        assertEquals("同名 (2).txt", second?.fileName)
        assertEquals("同名 (3).txt", third?.fileName)
        assertEquals("aaa", File(first!!.filePath!!).readText())
        assertEquals("bbb", File(second!!.filePath!!).readText())
        assertEquals("ccc", File(third!!.filePath!!).readText())
    }

    @Test
    fun emptyFileIsAllowed() {
        val directory = File(temp.root, "Download/文件互传助手")
        val publisher = DirectoryReceivedFilePublisher({ directory }, "下载/文件互传助手")
        val saved = publisher.save("empty.bin", 0L, ByteArrayInputStream(ByteArray(0)), {})
        assertNotNull(saved)
        assertTrue(File(saved!!.filePath!!).isFile)
        assertEquals(0L, File(saved.filePath!!).length())
    }

    @Test
    fun interruptedStreamCleansUpPartialFile() {
        val directory = File(temp.root, "Download/文件互传助手")
        val publisher = DirectoryReceivedFilePublisher({ directory }, "下载/文件互传助手")
        val failing = object : InputStream() {
            private var served = 0

            override fun read(): Int = throw IOException("中断")

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (served >= 10) throw IOException("中断")
                val count = minOf(len, 10 - served)
                for (i in 0 until count) b[off + i] = 'x'.code.toByte()
                served += count
                return count
            }
        }
        val saved = publisher.save("half.bin", 100L, failing, {})
        assertNull(saved)
        assertTrue("失败时应删除半截文件", (directory.listFiles() ?: emptyArray()).isEmpty())
    }

    @Test
    fun missingDirectoryIsCreated() {
        val directory = File(temp.root, "nested/Download/文件互传助手")
        val publisher = DirectoryReceivedFilePublisher({ directory }, "下载/文件互传助手")
        val saved = publisher.save("a.txt", 1, ByteArrayInputStream("a".toByteArray()), {})
        assertNotNull(saved)
        assertTrue(directory.isDirectory)
    }
}
