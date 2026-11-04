package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class FileNamesTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun sanitizeExtractsLastPathSegment() {
        assertEquals("passwd", FileNames.sanitizeIncoming("../../etc/passwd"))
        assertEquals("win.ini", FileNames.sanitizeIncoming("..\\..\\windows\\win.ini"))
        assertEquals("文件.txt", FileNames.sanitizeIncoming("dir/子目录/文件.txt"))
        assertEquals("photo.jpg", FileNames.sanitizeIncoming("C:/Users/me/photo.jpg"))
        assertEquals("报告.pdf", FileNames.sanitizeIncoming("  报告.pdf  "))
    }

    @Test
    fun sanitizeRejectsEmptyAndDotNames() {
        assertNull(FileNames.sanitizeIncoming(null))
        assertNull(FileNames.sanitizeIncoming(""))
        assertNull(FileNames.sanitizeIncoming("   "))
        assertNull(FileNames.sanitizeIncoming("."))
        assertNull(FileNames.sanitizeIncoming(".."))
        assertNull(FileNames.sanitizeIncoming("../"))
        assertNull(FileNames.sanitizeIncoming("dir/.."))
    }

    @Test
    fun sanitizeStripsControlCharacters() {
        val name = FileNames.sanitizeIncoming("a\u0000b\u0001c.txt")
        assertEquals("abc.txt", name)
    }

    @Test
    fun sanitizeClipsLongNamesButKeepsExtension() {
        val longName = "a".repeat(300) + ".txt"
        val safe = FileNames.sanitizeIncoming(longName)
        assertTrue((safe?.length ?: 0) <= 120)
        assertTrue(safe!!.endsWith(".txt"))
    }

    @Test
    fun uniqueNameNumbersDuplicates() {
        assertEquals("报告.pdf", FileNames.uniqueName(emptySet(), "报告.pdf"))
        assertEquals("报告 (2).pdf", FileNames.uniqueName(setOf("报告.pdf"), "报告.pdf"))
        assertEquals("报告 (3).pdf", FileNames.uniqueName(setOf("报告.pdf", "报告 (2).pdf"), "报告.pdf"))
        assertEquals("README (2)", FileNames.uniqueName(setOf("README"), "README"))
        assertEquals("a.txt", FileNames.uniqueName(setOf("b.txt"), "a.txt"))
        assertEquals("照片.jpg", FileNames.uniqueName(setOf("视频.mp4", "文档.docx"), "照片.jpg"))
    }

    @Test
    fun uniqueFileAddsNumberSuffixForDuplicates() {
        val directory = temp.newFolder("received")
        val first = FileNames.uniqueFile(directory, "报告.pdf")
        assertEquals("报告.pdf", first.name)
        first.writeText("first")

        val second = FileNames.uniqueFile(directory, "报告.pdf")
        assertEquals("报告 (2).pdf", second.name)
        second.writeText("second")

        val third = FileNames.uniqueFile(directory, "报告.pdf")
        assertEquals("报告 (3).pdf", third.name)
    }

    @Test
    fun uniqueFileHandlesNamesWithoutExtension() {
        val directory = temp.newFolder("received-noext")
        val first = FileNames.uniqueFile(directory, "README")
        first.writeText("x")
        assertEquals("README (2)", FileNames.uniqueFile(directory, "README").name)
    }

    @Test
    fun uniqueFileKeepsTargetInsideDirectory() {
        val directory = temp.newFolder("received-safe")
        val target = FileNames.uniqueFile(directory, "file.txt")
        assertEquals(directory.absolutePath, target.parentFile?.absolutePath)
        assertEquals(File(directory, "file.txt").absolutePath, target.absolutePath)
    }

    @Test
    fun formatSizeUsesReadableUnits() {
        assertEquals("0 B", FileNames.formatSize(0))
        assertEquals("512 B", FileNames.formatSize(512))
        assertEquals("1 KB", FileNames.formatSize(1024))
        assertEquals("1.5 KB", FileNames.formatSize(1536))
        assertEquals("1 MB", FileNames.formatSize(1024 * 1024))
        assertEquals("5 MB", FileNames.formatSize(5L * 1024 * 1024))
        assertEquals("未知大小", FileNames.formatSize(-1))
        assertFalse(FileNames.formatSize(999_999).isEmpty())
    }
}
